#!/bin/sh

LC_ALL=C
LANG=C
export LC_ALL LANG

HTTP_BACKEND=${HTTP_BACKEND:-auto}

info()
{
    printf '[%s] %s\n' "$(date)" "$*" >&2
}

die()
{
    printf '%s\n' "$1" >&2
    exit "${2:-1}"
}

check_cmd_common()
{
    for check_name in awk date grep od printf sed sleep tr; do
        command -v "$check_name" >/dev/null 2>&1 ||
            die "Cannot find command: $check_name"
    done
    # bc is checked only when encryption is actually needed.
}

check_cmd_curl()
{
    command -v curl >/dev/null 2>&1
}

check_cmd_wget()
{
    command -v wget >/dev/null 2>&1 || return 1

    # 部分精简版 BusyBox wget 没有 POST 支持。
    wget --help 2>&1 | grep -q -- '--post-data'
}

check_cmd_nc()
{
    command -v nc >/dev/null 2>&1
}

check_cmd()
{
    check_cmd_common

    case "${HTTP_BACKEND:-auto}" in
        auto)
            if check_cmd_curl; then
                HTTP_BACKEND=curl
            elif check_cmd_wget; then
                HTTP_BACKEND=wget
            elif check_cmd_nc; then
                HTTP_BACKEND=nc
            else
                die "Cannot find a usable curl, wget, or nc"
            fi
            ;;
        curl)
            check_cmd_curl || die "Cannot find curl"
            HTTP_BACKEND=curl
            ;;
        wget)
            check_cmd_wget ||
                die "wget is unavailable or lacks --post-data support"
            HTTP_BACKEND=wget
            ;;
        nc)
            check_cmd_nc || die "Cannot find nc"
            HTTP_BACKEND=nc
            ;;
        *)
            die "HTTP_BACKEND must be auto, curl, wget, or nc"
            ;;
    esac

    HTTP_GET=${HTTP_BACKEND}_get
    HTTP_POST=${HTTP_BACKEND}_post
    info "HTTP backend: $HTTP_BACKEND"
}

get()
{
    "$HTTP_GET" "$@"
}

post()
{
    "$HTTP_POST" "$@"
}

curl_get()
{
    curl -q --noproxy '*' -fsS --http1.0 \
        --connect-timeout 5 --max-time 15 \
        -A hust-network-login \
        -H 'Connection: close' -H 'Accept-Encoding: identity' \
        -- "http://$1:$2/"
}

curl_post()
{
    curl -q --noproxy '*' -fsS --http1.0 \
        --connect-timeout 5 --max-time 15 \
        -A hust-network-login \
        -H 'Connection: close' -H 'Accept-Encoding: identity' \
        -H 'Content-Type: application/x-www-form-urlencoded; charset=UTF-8' \
        --data-raw "$4" -- "http://$1:$2$3"
}

wget_get()
{
    wget -q -O - -T 15 -t 1 -Y off \
        -U hust-network-login \
        --header 'Connection: close' \
        --header 'Accept-Encoding: identity' \
        -- "http://$1:$2/"
}

wget_post()
{
    wget -q -O - -T 15 -t 1 -Y off \
        -U hust-network-login \
        --header 'Connection: close' \
        --header 'Accept-Encoding: identity' \
        --header 'Content-Type: application/x-www-form-urlencoded; charset=UTF-8' \
        --post-data "$4" \
        -- "http://$1:$2$3"
}

nc_skip_header()
{
    awk -v final_lf="$1" '
        NR == 1 {
            line = $0
            sub(/\r$/, "", line)
            split(line, status, /[ \t]+/)
            if (status[1] !~ /^HTTP\/1\.[01]$/ ||
                status[2] !~ /^[23][0-9][0-9]$/) {
                bad = 1
                exit
            }
            next
        }
        !header_finished {
            line = $0
            sub(/\r$/, "", line)
            if (line == "") {
                header_finished = 1
                next
            }
            lower = tolower(line)
            if (lower ~ /^transfer-encoding:/ ||
                (lower ~ /^content-encoding:/ &&
                 lower !~ /^content-encoding:[ \t]*identity[ \t]*$/)) {
                bad = 1
                exit
            }
            if (lower ~ /^content-length:/) {
                sub(/^[^:]*:[ \t]*/, "", line)
                sub(/[ \t]*$/, "", line)
                if (line !~ /^[0-9]+$/ ||
                    (has_length && expected != line + 0)) {
                    bad = 1
                    exit
                }
                has_length = 1
                expected = line + 0
            }
            next
        }
        {
            received += length($0) + 1
            body_lines++
            print
        }
        END {
            if (body_lines && !final_lf) received--
            if (bad || !header_finished ||
                (has_length && received != expected)) exit 1
        }
    '
}

nc_request()
(
    # Subshell function body isolates these variables in portable sh.
    # Arguments: method, host, port, path, body.
    nc_body=$5
    nc_raw=$(
        {
            printf '%s %s HTTP/1.0\r\n' "$1" "$4"
            printf 'Host: %s:%s\r\n' "$2" "$3"
            printf '%s\r\n' 'User-Agent: hust-network-login' \
                'Accept: */*' 'Accept-Encoding: identity' 'Connection: close'
            if [ "$1" = POST ]; then
                printf 'Content-Length: %s\r\n' "${#nc_body}"
                printf '%s\r\n' \
                    'Content-Type: application/x-www-form-urlencoded; charset=UTF-8'
            fi
            printf '\r\n'
            if [ "$1" = POST ]; then
                printf '%s' "$nc_body"
            fi
        } | nc -w 15 "$2" "$3"
        nc_status=$?
        printf '.'
        exit "$nc_status"
    ) || return 1
    nc_raw=${nc_raw%.}

    nc_lf='
'
    case "$nc_raw" in
        *"$nc_lf") nc_final_lf=1 ;;
        *) nc_final_lf=0 ;;
    esac

    if ! printf '%s' "$nc_raw" | nc_skip_header "$nc_final_lf"; then
        info 'Invalid, incomplete, unsupported, or HTTP-error response from nc'
        return 1
    fi
)

nc_get()
{
    nc_request GET "$1" "$2" / ''
}

nc_post()
{
    nc_request POST "$1" "$2" "$3" "$4"
}

urlencode()
{
    # Encode input bytes, including spaces, LF, and UTF-8 bytes.
    printf '%s' "$1" | od -An -v -t u1 | awk '
        {
            for (i = 1; i <= NF; i++) {
                n = $i + 0
                if ((n >= 48 && n <= 57) || (n >= 65 && n <= 90) ||
                    (n >= 97 && n <= 122) ||
                    n == 45 || n == 46 || n == 95 || n == 126)
                    printf "%c", n
                else
                    printf "%%%02X", n
            }
        }
    '
}

enc()
(
    command -v bc >/dev/null 2>&1 || {
        info 'Cannot find bc; plaintext password encryption requires bc'
        return 1
    }
    enc_c=$(printf '%s' "$1" | od -An -t x1 -v |
        tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')
    [ -n "$enc_c" ] || return 1
    enc_e=10001
    enc_n=94DD2A8675FB779E6B9F7103698634CD400F27A154AFA67AF6166A43FC26417222A79506D34CACC7641946ABDA1785B7ACF9910AD6A0978C91EC84D40B71D2891379AF19FFB333E7517E390BD26AC312FE940C340466B4A5D4AF1D65C3B5944078F96A1A51A5A53E4BC302818B7C9F63C4A1B07BD7D874CEF1C3D4B2F5EB7871
    enc_result=$(BC_LINE_LENGTH=0 bc <<EOF
scale = 0
obase = 16
ibase = 16
x = $enc_c
y = $enc_e
m = $enc_n
a = 1
while (y) {
    if (y % 2 == 1) {
        a = a * x % m
    }
    x = x * x % m
    y /= 2
}
a
EOF
    ) || return 1
    # Some bc implementations wrap output with a backslash and newline.
    enc_result=$(printf '%s' "$enc_result" |
        tr -d '\\[:space:]' | tr '[:upper:]' '[:lower:]')
    case "$enc_result" in
        ''|*[!0-9a-f]*) info 'Invalid encryption result from bc'; return 1 ;;
    esac
    [ "${#enc_result}" -le 256 ] || return 1
    printf '%256s' "$enc_result" | tr ' ' 0
)

login()
{
    username=$1
    password=$2

    resp=$(get www.baidu.com 80) || {
        info 'Probe request failed'
        return 1
    }
    [ -n "$resp" ] || { info 'Empty probe response'; return 1; }

    if ! printf '%s' "$resp" | grep -q '/eportal/index[.]jsp'; then
        return 0
    fi

    portal_url=$(printf '%s\n' "$resp" |
        sed -n "s|.*\(http://[^/\"'[:space:]<>]*/eportal/index[.]jsp?[^\"'[:space:]<>]*\).*|\1|p" |
        sed -n '1p')
    [ -n "$portal_url" ] || {
        info 'Cannot extract the expected HTTP portal URL from the response body'
        return 1
    }

    portal_ip=${portal_url#http://}
    portal_ip=${portal_ip%%/*}
    query_string=${portal_url#*\?}
    case "$portal_ip" in
        *:*) post_ip=${portal_ip%:*}; post_port=${portal_ip##*:} ;;
        *) post_ip=$portal_ip; post_port=80 ;;
    esac
    case "$post_ip" in
        ''|*[!a-zA-Z0-9.-]*) info 'Unsupported portal hostname'; return 1 ;;
    esac
    case "$post_port" in
        ''|*[!0-9]*) info 'Invalid portal port'; return 1 ;;
    esac
    if [ "${#post_port}" -gt 5 ] || [ "$post_port" -lt 1 ] ||
       [ "$post_port" -gt 65535 ]; then
        info 'Invalid portal port'
        return 1
    fi
    info "portal: $post_ip:$post_port"

    mac=$(printf '%s\n' "$query_string" |
        sed -n 's/.*mac=\([^&][^&]*\).*/\1/p')

    if [ "${#password}" -eq 256 ]; then
        case "$password" in
            *[!0-9a-fA-F]*) info 'Encrypted password must be hexadecimal'; return 1 ;;
        esac
        encrypt_pass=$password
    else
        [ -n "$mac" ] || { info 'Cannot extract portal MAC'; return 1; }
        info 'Encrypting password'
        encrypt_pass=$(enc "$password>$mac") || return 1
    fi

    user_encoded=$(urlencode "$username") || return 1
    query_string=$(urlencode "$query_string") || return 1
    body="userId=$user_encoded&password=$encrypt_pass&service=&queryString=$query_string&passwordEncrypt=true"

    resp=$(post "$post_ip" "$post_port" \
        '/eportal/InterFace.do?method=login' "$body") || {
        info 'Login request failed'
        return 1
    }
    info "login resp: $resp"
    printf '%s' "$resp" | grep -q 'success'
}

main()
{
    username=
    password=

    IFS= read -r username || :
    IFS= read -r password || :
    [ -n "$username" ] || die 'Missing username in config'
    [ -n "$password" ] || die 'Missing password in config'

    while :; do
        if login "$username" "$password"; then
            info 'login ok. awaiting...'
            sleep 15
        else
            info 'error!'
            sleep 1
        fi
    done
}


[ "$#" -eq 1 ] || die "Usage: $0 CONFIG"
[ -f "$1" ] && [ -r "$1" ] || die "Cannot read config: $1"
check_cmd
main < "$1"
