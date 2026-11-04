#!/usr/bin/env bash
# Atoll_Paco: diagnóstico de la portada HD de TIDAL. Hace las mismas peticiones
# que TidalArtworkResolver y dice en qué paso falla. No imprime el secret ni el token.
#
# Uso:  ./scripts/tidal-debug.sh                       (usa la canción que suena ahorita)
#       ./scripts/tidal-debug.sh "Título" "Artista"

set -euo pipefail

SERVICE="com.pacocerv08.AtollPaco.tidal"
R="/Applications/Atoll.app/Contents/Resources"

TIDAL_CLIENT_ID="$(security find-generic-password -s "${SERVICE}" -a client-id -w 2>/dev/null || true)"
TIDAL_CLIENT_SECRET="$(security find-generic-password -s "${SERVICE}" -a client-secret -w 2>/dev/null || true)"
export TIDAL_CLIENT_ID TIDAL_CLIENT_SECRET

if [ -z "${TIDAL_CLIENT_ID}" ] || [ -z "${TIDAL_CLIENT_SECRET}" ]; then
    echo "❌ No encontré las credenciales en el Keychain. Corre ./scripts/tidal-credentials.sh"
    exit 1
fi

if [ $# -ge 2 ]; then
    export SONG_TITLE="$1" SONG_ARTIST="$2" SONG_ALBUM="${3:-}"
else
    NOW="$(/usr/bin/perl "${R}/mediaremote-adapter.pl" "${R}/MediaRemoteAdapter.framework" get 2>/dev/null || true)"
    export NOW
    eval "$(python3 - <<'PY'
import json, os, shlex
try:
    d = json.loads(os.environ.get("NOW") or "{}")
except Exception:
    d = {}
for k, v in (("SONG_TITLE", d.get("title", "")), ("SONG_ARTIST", d.get("artist", "")),
             ("SONG_ALBUM", d.get("album", "")), ("SONG_BUNDLE", d.get("bundleIdentifier", "")),
             ("SONG_PARENT", d.get("parentApplicationBundleIdentifier", ""))):
    print(f"export {k}={shlex.quote(v or '')}")
PY
)"
    echo "→ Sonando ahorita: '${SONG_TITLE}' — '${SONG_ARTIST}' (álbum '${SONG_ALBUM}')"
    echo "  bundleIdentifier=${SONG_BUNDLE:-—}  parentApplicationBundleIdentifier=${SONG_PARENT:-—}"
fi

python3 - <<'PY'
import base64, json, os, re, unicodedata, urllib.error, urllib.parse, urllib.request

def norm(s):
    s = unicodedata.normalize("NFKD", s or "").encode("ascii", "ignore").decode().lower()
    return re.sub(r"\s+", " ", re.sub(r"[^a-z0-9]+", " ", s)).strip()

def canon(s):
    s = re.sub(r"\([^)]*\)|\[[^\]]*\]", " ", s or "")
    s = re.sub(r"\s-\s(?:\d{4}\s)?(?:remaster(?:ed)?|live|edit|mix|version|mono|stereo).*$", " ", s, flags=re.I)
    return norm(s)

def call(url, headers=None, data=None):
    req = urllib.request.Request(url, data=data, headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()
    except Exception as e:
        return -1, str(e).encode()

title, artist, album = os.environ["SONG_TITLE"], os.environ["SONG_ARTIST"], os.environ.get("SONG_ALBUM", "")
cid, secret = os.environ["TIDAL_CLIENT_ID"], os.environ["TIDAL_CLIENT_SECRET"]
country = os.environ.get("COUNTRY", "MX")

print("\n[1] Token (auth.tidal.com)")
basic = base64.b64encode(f"{cid}:{secret}".encode()).decode()
code, body = call("https://auth.tidal.com/v1/oauth2/token",
                  {"Authorization": f"Basic {basic}", "Content-Type": "application/x-www-form-urlencoded"},
                  b"grant_type=client_credentials")
print("   HTTP", code)
if code != 200:
    print("   ❌", body[:400].decode(errors="replace"))
    raise SystemExit(1)
token = json.loads(body)["access_token"]
H = {"Authorization": f"Bearer {token}", "Accept": "application/vnd.api+json"}
print("   ✅ token ok")

q = f"{canon(title)} {artist}"
url = "https://openapi.tidal.com/v2/searchResults?" + urllib.parse.urlencode(
    {"filter[query]": q, "countryCode": country, "include": "tracks"})
print(f"\n[2] Búsqueda: {q!r}")
code, body = call(url, H)
print("   HTTP", code)
if code != 200:
    print("   ❌", body[:600].decode(errors="replace"))
    raise SystemExit(1)
doc = json.loads(body)
data = doc.get("data")
resources = data if isinstance(data, list) else ([data] if data else [])
print(f"   data es {'lista' if isinstance(data, list) else type(data).__name__} con {len(resources)} recurso(s)")
rel = [t for r in resources for t in (((r.get("relationships") or {}).get("tracks") or {}).get("data") or [])]
inc = {r["id"]: r for r in doc.get("included", []) if r.get("type") == "tracks"}
if not rel:
    rel = [{"id": r["id"]} for r in doc.get("included", []) if r.get("type") == "tracks"]
    print("   (sin linkage en relationships; usando included)")
print(f"   {len(rel)} tracks en relationships, {len(inc)} en included")
for t in rel[:6]:
    print("   -", t["id"], (inc.get(t["id"], {}).get("attributes") or {}).get("title"))
cands = [t["id"] for t in rel
         if (lambda g: g == canon(title) or canon(title) in g or g in canon(title))(
             canon((inc.get(t["id"], {}).get("attributes") or {}).get("title", "")))]
print("   candidatos por título:", cands[:3] or "NINGUNO ❌")
if not cands:
    raise SystemExit(1)

for tid in cands[:3]:
    for include in ("artists,albums.coverArt", "artists,albums"):
        url = f"https://openapi.tidal.com/v2/tracks/{tid}?" + urllib.parse.urlencode(
            {"countryCode": country, "include": include})
        code, body = call(url, H)
        print(f"\n[3] Track {tid} include={include} → HTTP {code}")
        if code == 200:
            break
        print("   ", body[:400].decode(errors="replace"))
    if code != 200:
        continue
    doc = json.loads(body)
    arts = [r["attributes"].get("name") for r in doc.get("included", []) if r.get("type") == "artists"]
    albs = [r for r in doc.get("included", []) if r.get("type") == "albums"]
    works = {r["id"]: r for r in doc.get("included", []) if r.get("type") == "artworks"}
    print("   artistas:", arts)
    print("   álbumes:", [a["attributes"].get("title") for a in albs])
    print("   artworks incluidos:", len(works))
    for a in albs:
        ids = [x["id"] for x in ((a.get("relationships") or {}).get("coverArt") or {}).get("data") or []]
        if not ids or not all(i in works for i in ids):
            url = f"https://openapi.tidal.com/v2/albums/{a['id']}/relationships/coverArt?" + urllib.parse.urlencode(
                {"countryCode": country, "include": "coverArt"})
            code, body = call(url, H)
            print(f"   coverArt del álbum {a['id']} → HTTP {code}")
            if code == 200:
                d2 = json.loads(body)
                works.update({r["id"]: r for r in d2.get("included", []) if r.get("type") == "artworks"})
                ids = [x["id"] for x in d2.get("data") or []]
            else:
                print("   ", body[:400].decode(errors="replace"))
        for i in ids:
            files = (works.get(i, {}).get("attributes") or {}).get("files") or []
            print("   archivos:", [((f.get("meta") or {}).get("width"), f.get("href")) for f in files][:6])
    break
PY
