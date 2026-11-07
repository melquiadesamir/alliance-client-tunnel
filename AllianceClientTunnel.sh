#!/data/data/com.termux/files/usr/bin/bash

# --- CONFIGURACIÓN ---
# Solo CLOUDFLARED_HOST es configurable. Se puede pasar por:
#   1) argumento:  ./vpn_client.sh -H mi-host.ejemplo.com
#   2) variable de entorno: export CLOUDFLARED_HOST="mi-host.ejemplo.com"
#   3) archivo .env:  ./vpn_client.sh --env ./vpn.env
CLOUDFLARED_HOST="${CLOUDFLARED_HOST:-}"
CLOUDFLARED_PORT="2034"
WSTUNNEL_WS_URL="wss://localhost:${CLOUDFLARED_PORT}"
WSTUNNEL_LOCAL_FORWARD="udp://127.0.0.1:2022:127.0.0.1:2022?timeout_sec=0"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GLOBAL_BIN="$PREFIX/bin"

CLOUDFLARED_PID=""
WSTUNNEL_PID=""

usage() {
    cat <<EOF
Uso: $0 -H HOST [opciones]

Opciones:
  -H, --host HOST    Hostname de Cloudflare (requerido)
  -e, --env FILE     Cargar CLOUDFLARED_HOST desde un archivo .env
  -h, --help         Mostrar esta ayuda

También puedes usar:
  export CLOUDFLARED_HOST="mi-host.ejemplo.com"
  $0

Ejemplo:
  $0 -H alliance.visionary.dpdns.org
  $0 --env ./vpn.env
EOF
}

# --- PARSEO DE ARGUMENTOS ---
ENV_FILE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -H|--host) CLOUDFLARED_HOST="$2"; shift 2 ;;
        -e|--env)  ENV_FILE="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "[ERROR] Opción desconocida: $1"; usage; exit 1 ;;
    esac
done

# Cargar .env si se indicó (no sobreescribe si ya vino por -H o variable de entorno)
if [ -n "$ENV_FILE" ]; then
    if [ -f "$ENV_FILE" ]; then
        # shellcheck disable=SC1090
        set -a; source "$ENV_FILE"; set +a
        echo "[OK] Configuración cargada desde $ENV_FILE"
    else
        echo "[ERROR] Archivo .env no encontrado: $ENV_FILE"
        exit 1
    fi
fi

# Validación
if [ -z "$CLOUDFLARED_HOST" ]; then
    echo "[ERROR] Falta CLOUDFLARED_HOST. Usa -H, --env, o export CLOUDFLARED_HOST."
    usage
    exit 1
fi

echo "[*] Host configurado: $CLOUDFLARED_HOST"
echo "[*] Puerto local:     $CLOUDFLARED_PORT"
echo "[*] WS URL:           $WSTUNNEL_WS_URL"
echo "[*] Forward:          $WSTUNNEL_LOCAL_FORWARD"

# --- FUNCIÓN DE LIMPIEZA ---
cleanup() {
    echo -e "\n[SISTEMA] Cerrando túneles..."
    if [ -n "$WSTUNNEL_PID" ] && kill -0 "$WSTUNNEL_PID" 2>/dev/null; then
        kill "$WSTUNNEL_PID" 2>/dev/null
        echo "[SISTEMA] wstunnel detenido."
    fi
    if [ -n "$CLOUDFLARED_PID" ] && kill -0 "$CLOUDFLARED_PID" 2>/dev/null; then
        kill "$CLOUDFLARED_PID" 2>/dev/null
        echo "[SISTEMA] cloudflared detenido."
    fi
    exit 0
}
trap cleanup EXIT INT TERM

# --- FUNCIÓN: asegurar dependencia del sistema ---
PKG_UPDATED=0
ensure_dep() {
    local cmd="$1"
    local pkg_name="${2:-$1}"
    if command -v "$cmd" &> /dev/null; then
        return 0
    fi
    echo "[!] Falta '$cmd'. Se necesita para continuar."
    if [ "$PKG_UPDATED" -eq 0 ]; then
        echo "[*] Actualizando repositorios (pkg update)..."
        pkg update -y || { echo "[ERROR] Falló pkg update."; exit 1; }
        PKG_UPDATED=1
    fi
    echo "[*] Instalando $pkg_name..."
    pkg install -y "$pkg_name" || { echo "[ERROR] No se pudo instalar $pkg_name."; exit 1; }
    echo "[OK] $pkg_name instalado."
}

# --- VERIFICACIÓN DE INSTANCIAS YA CORRIENDO ---
echo "[*] Verificando si ya hay instancias corriendo..."
CLOUDFLARED_RUNNING=$(pgrep -f "cloudflared access tcp" 2>/dev/null)
if [ -n "$CLOUDFLARED_RUNNING" ]; then
    echo "[!] Ya hay un cloudflared corriendo (PID(s): $CLOUDFLARED_RUNNING). Ciérralo primero."
    exit 1
fi

WSTUNNEL_RUNNING=$(pgrep -f "wstunnel client" 2>/dev/null)
if [ -n "$WSTUNNEL_RUNNING" ]; then
    echo "[!] Ya hay un wstunnel corriendo (PID(s): $WSTUNNEL_RUNNING). Ciérralo primero."
    exit 1
fi
echo "[OK] No hay instancias previas."

# --- DETECCIÓN DE ARQUITECTURA ---
ARCH=$(uname -m)
if [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then
    CLOUDFLARED_ARCH="arm64"
    WSTUNNEL_ARCH="android_arm64"
elif [[ "$ARCH" == "armv7l" || "$ARCH" == "arm" ]]; then
    CLOUDFLARED_ARCH="arm"
    WSTUNNEL_ARCH="android_arm"
else
    echo "[ERROR] Arquitectura $ARCH no soportada."
    exit 1
fi

# --- VERIFICACIÓN / DESCARGA DE CLOUDFLARED ---
CLOUDFLARED_BIN=""
if command -v cloudflared &> /dev/null; then
    CLOUDFLARED_BIN="cloudflared"
    echo "[OK] cloudflared encontrado en PATH."
elif [ -x "$SCRIPT_DIR/cloudflared" ]; then
    CLOUDFLARED_BIN="$SCRIPT_DIR/cloudflared"
    echo "[OK] cloudflared encontrado junto al script."
else
    echo "[!] cloudflared no encontrado. Se descargará."
    ensure_dep wget
    URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CLOUDFLARED_ARCH}"
    if wget -q "$URL" -O "$GLOBAL_BIN/cloudflared"; then
        chmod +x "$GLOBAL_BIN/cloudflared"
        CLOUDFLARED_BIN="cloudflared"
        echo "[OK] cloudflared instalado globalmente en $GLOBAL_BIN/cloudflared"
    else
        echo "[ERROR] No se pudo descargar cloudflared."
        exit 1
    fi
fi

# --- VERIFICACIÓN / DESCARGA DE WSTUNNEL ---
WSTUNNEL_BIN=""
if command -v wstunnel &> /dev/null; then
    WSTUNNEL_BIN="wstunnel"
    echo "[OK] wstunnel encontrado en PATH."
elif [ -x "$SCRIPT_DIR/wstunnel" ]; then
    WSTUNNEL_BIN="$SCRIPT_DIR/wstunnel"
    echo "[OK] wstunnel encontrado junto al script."
else
    echo "[!] wstunnel no encontrado. Se descargará."
    ensure_dep curl
    ensure_dep tar
    WSTUNNEL_URL=$(curl -s https://api.github.com/repos/erebe/wstunnel/releases/latest \
        | grep "browser_download_url.*${WSTUNNEL_ARCH}.tar.gz" \
        | cut -d '"' -f 4)
    if [ -z "$WSTUNNEL_URL" ]; then
        echo "[ERROR] No se pudo obtener la URL de descarga de wstunnel."
        exit 1
    fi
    echo "    Descargando desde: $WSTUNNEL_URL"
    TMP_DIR=$(mktemp -d)
    if curl -L -o "$TMP_DIR/wstunnel.tar.gz" "$WSTUNNEL_URL"; then
        tar -xzf "$TMP_DIR/wstunnel.tar.gz" -C "$TMP_DIR" wstunnel
        mv "$TMP_DIR/wstunnel" "$GLOBAL_BIN/wstunnel"
        chmod +x "$GLOBAL_BIN/wstunnel"
        rm -rf "$TMP_DIR"
        WSTUNNEL_BIN="wstunnel"
        echo "[OK] wstunnel instalado globalmente en $GLOBAL_BIN/wstunnel"
    else
        rm -rf "$TMP_DIR"
        echo "[ERROR] No se pudo descargar wstunnel."
        exit 1
    fi
fi

# --- EJECUCIÓN ---
echo "[*] Iniciando cloudflared access..."
"$CLOUDFLARED_BIN" access tcp --hostname "$CLOUDFLARED_HOST" --url "127.0.0.1:$CLOUDFLARED_PORT" &
CLOUDFLARED_PID=$!
sleep 3
if ! kill -0 "$CLOUDFLARED_PID" 2>/dev/null; then
    echo "[ERROR] cloudflared falló al iniciar."
    exit 1
fi
echo "[OK] cloudflared corriendo (PID: $CLOUDFLARED_PID)"

echo "[*] Iniciando wstunnel client..."
"$WSTUNNEL_BIN" client -L "$WSTUNNEL_LOCAL_FORWARD" "$WSTUNNEL_WS_URL" &
WSTUNNEL_PID=$!
echo "[OK] wstunnel corriendo (PID: $WSTUNNEL_PID)"

echo ""
echo "=========================================="
echo " Túneles activos. Presiona Ctrl+C para salir."
echo "=========================================="
wait
