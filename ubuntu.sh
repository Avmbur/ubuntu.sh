#!/usr/bin/env bash
#
# ubuntu.sh — универсальный скрипт постустановочной настройки и обслуживания
#             Ubuntu Server.
#
# Запуск:  sudo ./ubuntu.sh   (без sudo перезапустится сам)
#
# Скрипт многоразовый: каждый модуль сначала показывает текущее состояние
# и только потом что-то меняет. Повторный запуск ничего не ломает.
#
# Лог работы: /var/log/ubuntu-setup.log

# pipefail намеренно не включён. При нём конвейер, где читатель выходит
# раньше писателя, возвращает 141 от SIGPIPE: "ufw status | head -1 | grep -q"
# и "docker ps | grep -qx" начинали врать, как только вывода становилось много.
# Код первой команды конвейера важен только в run(), и там читается PIPESTATUS.
set -u

VERSION="1.0"
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "$0")"
LOG_FILE="/var/log/ubuntu-setup.log"
export DEBIAN_FRONTEND=noninteractive
# needrestart живёт своей жизнью и DEBIAN_FRONTEND не слушает; «l» — только
# перечислить службы, требующие перезапуска. Экспортируем, чтобы правило
# действовало и внутри чужих установщиков (get.docker.com зовёт apt сам).
export NEEDRESTART_MODE=l

# printf выравнивает по байтам, а кириллица занимает два байта на символ:
# без UTF-8-локали все колонки в таблицах разъезжаются. Заодно вывод
# системных команд остаётся английским, что удобнее для лога.
if locale -a 2>/dev/null | grep -qix 'C.utf8'; then
    export LC_ALL=C.UTF-8
elif locale -a 2>/dev/null | grep -qix 'en_US.utf8'; then
    export LC_ALL=en_US.UTF-8
fi

# ── Оформление ──────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YLW=$'\033[1;33m'
    BLU=$'\033[0;34m'; CYN=$'\033[0;36m'; DIM=$'\033[2m'
    BLD=$'\033[1m';    RST=$'\033[0m'
else
    RED=''; GRN=''; YLW=''; BLU=''; CYN=''; DIM=''; BLD=''; RST=''
fi

log()  { printf '%s | %s\n' "$(date '+%F %T')" "$*" >>"$LOG_FILE" 2>/dev/null || true; }
info() { echo "${CYN}$*${RST}";   log "INFO: $*"; }
ok()   { echo "${GRN}✔ $*${RST}"; log "OK:   $*"; }
warn() { echo "${YLW}⚠ $*${RST}"; log "WARN: $*"; }
err()  { echo "${RED}✘ $*${RST}"; log "ERR:  $*"; }
hr()   { echo "${DIM}────────────────────────────────────────────────────────────────${RST}"; }

# Путь по меню. Цифры на разных уровнях значат разное — «1 → 7» это swap,
# а «3 → 7» раздел отката, — и без такой строки непонятно, где находишься.
crumbs() {  # crumbs "Сеть и доступ" "SSH"
    local out="Главное" p
    for p in "$@"; do out+=" ${DIM}›${RST} $p"; done
    echo
    echo "  ${DIM}${out}${RST}"
}

# printf в glibc отмеряет ширину поля в БАЙТАХ, а кириллица занимает по два
# байта на символ — поэтому "%-22s" разъезжается на русских подписях.
# Для них ширину считаем сами: ${#s} в UTF-8-локали возвращает символы.
pad() {  # pad "текст" ширина
    local s=$1 w=$2 n
    n=$(( w - ${#s} ))
    if (( n > 0 )); then printf '%s%*s' "$s" "$n" ""; else printf '%s' "$s"; fi
}
title(){ echo; echo "${BLD}${CYN}══ $* ══${RST}"; }

# Ввод 010 означает десять; длинное число не должно переполнять арифметику
# Bash и превращаться в допустимый номер другой записи.
parse_uint() {  # parse_uint значение минимум максимум
    local value=$1 minimum=$2 maximum=$3
    [[ $value =~ ^[0-9]+$ ]] || return 1
    value=${value#"${value%%[!0]*}"}; value=${value:-0}
    (( ${#value} <= ${#maximum} )) || return 1
    value=$((10#$value))
    (( value >= minimum && value <= maximum )) || return 1
    printf '%s' "$value"
}

plural() {  # plural 2 копия копии копий → «2 копии»
    local n=$1 one=$2 few=$3 many=$4 form
    if   (( n % 100 >= 11 && n % 100 <= 14 )); then form=$many
    elif (( n % 10 == 1 ));                    then form=$one
    elif (( n % 10 >= 2 && n % 10 <= 4 ));     then form=$few
    else                                            form=$many
    fi
    printf '%s %s' "$n" "$form"
}

# Читаем всегда с терминала: скрипт может быть запущен через пайп.
TTY_IN=/dev/stdin
[[ -r /dev/tty ]] && TTY_IN=/dev/tty

TERMINAL_SAVED=""
terminal_is_interactive() { [[ -t 0 ]] <"$TTY_IN"; }

terminal_restore() {
    [[ -n $TERMINAL_SAVED ]] || return 0
    stty "$TERMINAL_SAVED" <"$TTY_IN" 2>/dev/null || true
    TERMINAL_SAVED=""
}

terminal_init() {
    terminal_is_interactive || return 0
    local saved
    saved=$(stty -g <"$TTY_IN" 2>/dev/null) || return 1
    # Проверка в ask ловит остатки, но не чинит Backspace: без IUTF8
    # драйвер терминала стирает один байт вместо целой буквы UTF-8.
    stty iutf8 <"$TTY_IN" 2>/dev/null || return 1
    TERMINAL_SAVED=$saved
    trap terminal_restore EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
}

REPLY_VAL=""

# ask "Вопрос" [умолчание] [free]
# По умолчанию принимается только латиница: во всех полях скрипта — номера
# пунктов, порты, адреса, имена — кириллице взяться неоткуда, а забытая
# раскладка оставляет в строке целую букву (Backspace стирает байты, а не
# символы) и даёт невнятный отказ. Третий аргумент «free» снимает проверку
# там, где нелатинский ввод осмыслен.
ask() {
    local prompt=$1 def=${2:-} mode=${3:-ascii} ans clean
    while true; do
        if [[ -n $def ]]; then printf '%s [%s]: ' "$prompt" "$def"
        else                   printf '%s: ' "$prompt"; fi
        IFS= read -r ans <"$TTY_IN" || ans=''
        ans=${ans//$'\r'/}
        # Выбрасываем битые последовательности байт. Если у терминала не
        # выставлен iutf8, Backspace стирает один байт из двух в кириллической
        # букве, и огрызок вроде 0xD1 уезжает в команду — ufw на такое
        # отвечает «Bad source address», и причина совершенно не видна.
        # Код возврата iconv не смотрим: с ключом -c он и чистит вход, и
        # сообщает ненулевым кодом, что вход был битым. Берём результат, если
        # он непустой — пустой возможен только когда чистить было нечего.
        if command -v iconv &>/dev/null; then
            clean=$(printf '%s' "$ans" | iconv -c -f UTF-8 -t UTF-8 2>/dev/null)
            [[ -n $clean || -z $ans ]] && ans=$clean
        fi
        ans="${ans#"${ans%%[![:space:]]*}"}"
        ans="${ans%"${ans##*[![:space:]]}"}"

        # Сравниваем в байтовой локали: в UTF-8 одиночный битый байт для
        # регулярки не символ, и проверка его молча пропускала.
        if [[ $mode == ascii && -n $ans ]] \
           && printf '%s' "$ans" | LC_ALL=C grep -q '[^ -~]'; then
            warn "В строке есть символы не из латиницы: «${ans}»"
            echo "  ${DIM}Похоже, осталась буква от русской раскладки — Backspace стирает"
            echo "  байты, а не символы. Введи заново.${RST}"
            continue
        fi
        break
    done
    REPLY_VAL="${ans:-$def}"
}

ask_yn() {  # ask_yn "Вопрос"
    local prompt=$1 ans clean
    # Enter никогда не подтверждает действие; ответ по умолчанию указан словом.
    local hint="[y/N, Enter — нет]"
    while true; do
        printf '%s %s ' "$prompt" "$hint"
        IFS= read -r ans <"$TTY_IN" || ans=''
        # Оставляем только латиницу. Кириллическая буква занимает два байта, и
        # если у терминала не выставлен iutf8, Backspace стирает лишь один из
        # них — в строке остаётся невидимый огрызок, из-за которого ответ "Y"
        # переставал совпадать с шаблоном. Заодно отсекаются \r и пробелы.
        clean=${ans//[^A-Za-z]/}
        [[ -z ${ans//[[:space:]]/} ]] && clean=N
        case $clean in
            [Yy]*) return 0 ;;
            [Nn]*) return 1 ;;
            *)     echo "  Ответь ${BLD}y${RST} (да) или ${BLD}n${RST} (нет) — в английской раскладке." ;;
        esac
    done
}

confirm_danger() {  # confirm_danger "что произойдёт"
    echo
    echo "${YLW}${BLD}ВНИМАНИЕ${RST} ${YLW}$1${RST}"
    ask_yn "${BLD}Продолжить?${RST}"
}

pause() {
    echo
    printf '%s' "${BLU}Enter — продолжить...${RST}"
    IFS= read -r _ <"$TTY_IN" || true
    echo
}

# Выполнить команду с записью вывода в лог. Возвращает код команды.
run() {
    log "CMD: $*"
    local rc
    "$@" 2>&1 | tee -a "$LOG_FILE"
    rc=${PIPESTATUS[0]}
    if (( rc != 0 )); then log "CMD FAILED rc=$rc: $*"; fi
    return "$rc"
}

# То же, но без вывода на экран (для шумных команд).
run_quiet() {
    log "CMD: $*"
    local out rc
    out="$("$@" 2>&1)"; rc=$?
    [[ -n $out ]] && printf '%s\n' "$out" >>"$LOG_FILE"
    if (( rc != 0 )); then
        log "CMD FAILED rc=$rc: $*"
        printf '%s\n' "$out"
    fi
    return "$rc"
}

# ── Права и окружение ───────────────────────────────────────────────────────
require_root() {
    [[ $EUID -eq 0 ]] && return 0
    echo "${YLW}Скрипт ставит пакеты, правит /etc и управляет службами —"
    echo "поэтому ему нужны права root. Перезапускаюсь через sudo.${RST}"
    echo
    if ! command -v sudo &>/dev/null; then
        err "sudo не найден. Зайди под root и запусти скрипт заново."
        exit 1
    fi
    # Без -E: в некоторых sudoers сохранение окружения запрещено и sudo просто
    # откажется работать. Нужного нам здесь и не требуется — DEBIAN_FRONTEND
    # выставляется заново, а SUDO_USER sudo проставляет сам.
    exec sudo bash "$SCRIPT_PATH" "$@"
}

init_log() {
    touch "$LOG_FILE" 2>/dev/null || true
    chmod 640 "$LOG_FILE" 2>/dev/null || true
    log "=== запуск ubuntu.sh v$VERSION (вызвал: ${SUDO_USER:-root}) ==="
}

TARGET_USER="${SUDO_USER:-root}"

os_pretty() { ( . /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-Ubuntu}" ); }
virt_type() { systemd-detect-virt 2>/dev/null || echo none; }
is_kvm_guest() { local v; v=$(virt_type); [[ $v == kvm || $v == qemu ]]; }
primary_ip() { hostname -I 2>/dev/null | awk '{print $1}'; }

pkg_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "ok installed"; }

# Весь вывод скрипта идёт через tee в лог, то есть apt пишет в трубу. При этом
# dpkg он по умолчанию запускает на отдельном псевдотерминале, и два потока с
# разной трактовкой перевода строки сливаются в одну трубу — на экране лесенка.
# Use-Pty=0 убирает второй поток.
apt_get() { apt-get -o Dpkg::Use-Pty=0 "$@"; }

apt_updated=0
apt_refresh() {
    (( apt_updated == 1 )) && return 0
    info "Обновляю списки пакетов..."
    run apt_get update || { err "apt-get update завершился с ошибкой"; return 1; }
    apt_updated=1
}

pkg_install() {  # pkg_install пакет [пакет...]
    local p missing=()
    for p in "$@"; do pkg_installed "$p" || missing+=("$p"); done
    if (( ${#missing[@]} == 0 )); then
        echo "${DIM}  уже установлено: $*${RST}"
        return 0
    fi
    apt_refresh || return 1
    info "Устанавливаю: ${missing[*]}"
    run apt_get install -y "${missing[@]}" || return 1
    manifest_add "${missing[@]}"
}

# ── Учёт установленного ─────────────────────────────────────────────────────
# apt не отличает «поставил я» от «пришло с системой». Ведём свой список:
# через pkg_install проходят все установки скрипта, так что точка одна.
PKG_MANIFEST=/var/lib/ubuntu-sh/packages
CURRENT_MODULE=""

manifest_add() {
    local p
    mkdir -p "${PKG_MANIFEST%/*}" 2>/dev/null || return 0
    for p in "$@"; do
        grep -qxE "${p}\|.*" "$PKG_MANIFEST" 2>/dev/null && continue
        printf '%s|%s|%s\n' "$p" "$(date +%Y-%m-%d)" "${CURRENT_MODULE:-вручную}" >>"$PKG_MANIFEST"
    done
    log "MANIFEST += $*"
}

manifest_del() {
    [[ -f $PKG_MANIFEST ]] || return 0
    # Через grep, а не sed: в строках манифеста разделитель «|», и он же
    # разделитель адреса в sed — выражение разваливалось молча.
    local p tmp
    tmp=$(mktemp) || return 0
    cp "$PKG_MANIFEST" "$tmp"
    for p in "$@"; do
        grep -v "^${p}|" "$tmp" >"$tmp.new" 2>/dev/null
        mv -f "$tmp.new" "$tmp" 2>/dev/null || true
    done
    cat "$tmp" >"$PKG_MANIFEST"
    rm -f "$tmp" "$tmp.new"
    log "MANIFEST -= $*"
}

reboot_required() { [[ -f /var/run/reboot-required ]]; }

# Имя файла не доказывает, кто его создал: jail.local и override.conf могли
# быть настроены администратором. Старые установки без записи не присваиваем.
FILE_MANIFEST=/var/lib/ubuntu-sh/files

file_owned() { grep -Fxq -- "$1" "$FILE_MANIFEST" 2>/dev/null; }

file_manifest_add() {
    file_owned "$1" && return 0
    mkdir -p "${FILE_MANIFEST%/*}" || return 1
    printf '%s\n' "$1" >>"$FILE_MANIFEST" || return 1
    log "FILE MANIFEST += $1"
}

file_manifest_del() {
    [[ -f $FILE_MANIFEST ]] || return 0
    local tmp rc
    tmp=$(mktemp "${FILE_MANIFEST}.XXXXXX") || return 1
    grep -Fxv -- "$1" "$FILE_MANIFEST" >"$tmp"; rc=$?
    # grep возвращает 1 и при успешном удалении единственной записи.
    if (( rc > 1 )); then rm -f "$tmp"; return 1; fi
    if ! mv -f "$tmp" "$FILE_MANIFEST"; then rm -f "$tmp"; return 1; fi
    log "FILE MANIFEST -= $1"
}

file_write() {  # file_write путь [режим нового файла], содержимое — stdin
    local f=$1 mode=${2:-0644} tmp staged existed=0
    # Не следуем по ссылкам: иначе запись и последующее удаление затронут
    # разные объекты, а манифест будет обещать неверную принадлежность.
    if [[ -L $f || ( -e $f && ! -f $f ) ]]; then
        err "$f — не обычный файл. Настройка не записана."; return 1
    fi
    tmp=$(mktemp) || return 1
    if ! cat >"$tmp"; then rm -f "$tmp"; return 1; fi
    if [[ -f $f ]]; then
        existed=1
        if cmp -s -- "$tmp" "$f"; then rm -f "$tmp"; return 0; fi
        backup_file "$f" >/dev/null || { rm -f "$tmp"; return 1; }
    else
        file_manifest_del "$f" || { rm -f "$tmp"; return 1; }
    fi
    # SSH не должен остаться с обрезанным конфигом при обрыве сессии или
    # полном диске. Переименовываем готовый файл на той же файловой системе.
    staged=$(mktemp "${f}.XXXXXX") || { rm -f "$tmp"; return 1; }
    if (( existed )); then
        cp -a "$f" "$staged" || { rm -f "$tmp" "$staged"; return 1; }
    else
        chmod "$mode" "$staged" || { rm -f "$tmp" "$staged"; return 1; }
    fi
    if ! cat "$tmp" >"$staged" || ! mv -f "$staged" "$f"; then rm -f "$tmp" "$staged"; return 1; fi
    rm -f "$tmp"
    if (( existed == 0 )); then
        file_manifest_add "$f" || { err "$f записан, но не удалось сохранить его принадлежность."; return 1; }
    fi
    return 0
}

# ── Резервные копии ─────────────────────────────────────────────────────────
# Копии складываем в один каталог, а не рядом с оригиналом: иначе /etc
# зарастает файлами вида sshd_config.bak.1757068800, и через полгода
# непонятно, чьи они и можно ли их трогать.
BACKUP_DIR=/var/backups/ubuntu-sh

BACKUP_INDEX="$BACKUP_DIR/.index"

backup_file() {  # backup_file /etc/hosts — печатает путь новой или совпавшей копии
    local src=$1 name dst latest="" src_meta copy_meta
    [[ -f $src ]] || return 0
    IFS= read -r latest < <(backups_for "$src") || true
    # Повторный запрос копии внутри одной операции не создаёт вторую запись.
    # Одного cmp мало: изменённые владелец, группа и режим тоже нужны для отката.
    if [[ -n $latest && ! -L $src && ! -L $latest ]] && cmp -s -- "$src" "$latest"; then
        if src_meta=$(stat -c '%a:%u:%g' -- "$src") &&
           copy_meta=$(stat -c '%a:%u:%g' -- "$latest") && [[ $src_meta == "$copy_meta" ]]; then
            printf '%s\n' "$latest"
            return 0
        fi
    fi
    mkdir -p "$BACKUP_DIR" 2>/dev/null || return 1
    name=${src#/}; name=${name//\//_}
    # Несколько настроек SSH записываются за одну секунду: одно лишь время
    # в имени перетирало исходную копию следующей промежуточной версией.
    dst=$(mktemp --suffix=".$(date +%Y%m%d-%H%M%S)" "$BACKUP_DIR/${name}.XXXXXX") || return 1
    if cp -a "$src" "$dst" 2>/dev/null; then
        # Путь пишем в индекс, а не выводим обратно из имени: замена слэшей
        # на подчёркивания необратима — в самих именах файлов подчёркивания
        # тоже встречаются (authorized_keys, 20auto-upgrades).
        printf '%s\t%s\n' "${dst##*/}" "$src" >>"$BACKUP_INDEX" 2>/dev/null || {
            err "Не удалось записать индекс резервных копий."; return 1; }
        log "BACKUP: $src -> $dst"
        echo "$dst"
    else
        rm -f "$dst"
        err "Не удалось сохранить копию $src."
        return 1
    fi
}

# Возможные файлы скрипта. Удаление разрешает только запись в FILE_MANIFEST.
OWNED_FILES=(
    /etc/ssh/sshd_config.d/00-ubuntu-sh.conf
    /etc/systemd/system/ssh.socket.d/override.conf
    /etc/systemd/journald.conf.d/99-ubuntu-sh.conf
    /etc/sysctl.d/99-disable-ipv6.conf
    /etc/sysctl.d/99-swappiness.conf
    /etc/fail2ban/jail.local
    /etc/apt/apt.conf.d/20auto-upgrades
    /etc/apt/apt.conf.d/52unattended-upgrades-local
    /etc/cloud/cloud-init.disabled
)

# Чужие файлы, в которые скрипт дописывает свой кусок: удалять нельзя,
# можно только убрать этот кусок или восстановить файл из копии.
SHARED_FILES=(
    "/etc/ufw/after.rules|блок правил Docker+UFW"
    "/etc/ufw/after6.rules|блок правил Docker+UFW (IPv6)"
    "/var/lib/ubuntu-sh/docker-ports|разрешения внешних портов Docker"
    "/etc/fstab|строка своп-файла"
    "/etc/hosts|строка 127.0.1.1"
    "/etc/docker/daemon.json|ротация логов контейнеров"
    "/etc/default/zramswap|доля RAM под zram"
    "/etc/default/motd-news|разрешение новостей MOTD"
    "/etc/default/apport|разрешение отчётов Apport"
)

# "Archived and active journals take up 1.2G in the file system." -> "1.2G"
journal_usage() {
    local s
    s=$(journalctl --disk-usage 2>/dev/null) || { echo "?"; return; }
    s=$(printf '%s' "$s" | sed -nE 's/.*take up ([0-9.]+[KMGTPE]?i?B?).*/\1/p')
    echo "${s:-?}"
}

svc_state() {  # красивый статус юнита
    local unit=$1 state
    if ! systemctl list-unit-files "$unit" &>/dev/null || \
       ! systemctl cat "$unit" &>/dev/null; then
        echo "${DIM}не установлен${RST}"; return
    fi
    if systemctl is-active --quiet "$unit"; then echo "${GRN}active${RST}"
    else
        # is-active печатает inactive/failed и возвращает ненулевой код.
        state=$(systemctl is-active "$unit" 2>/dev/null)
        echo "${YLW}${state:-неизвестно}${RST}"
    fi
}

# ════════════════════════════════════════════════════════════════════════════
#  SSH: определение реального порта
# ════════════════════════════════════════════════════════════════════════════

ssh_socket_enabled() { systemctl is-enabled ssh.socket &>/dev/null; }

ssh_ports() {
    local raw ports p
    if ssh_socket_enabled || systemctl is-active --quiet ssh.socket; then
        # Port в sshd_config не описывает сокеты, переданные systemd.
        raw=$(systemctl show ssh.socket -p Listen --value 2>/dev/null) || return 1
        ports=$(grep -oE '[0-9]+ \(Stream\)' <<<"$raw" | awk '{print $1}')
    else
        raw=$(sshd -T 2>/dev/null) || return 1
        ports=$(awk '$1 == "port" {print $2}' <<<"$raw")
    fi
    [[ -n $ports ]] || return 1
    while IFS= read -r p; do
        [[ $p =~ ^[0-9]{1,5}$ ]] && (( 10#$p >= 1 && 10#$p <= 65535 )) || return 1
    done <<<"$ports"
    printf '%s\n' "$ports" | sort -nu
}

ssh_port() {
    local ports
    ports=$(ssh_ports) || return 1
    printf '%s\n' "${ports%%$'\n'*}"
}

ssh_ports_display() {
    local ports
    ports=$(ssh_ports) || { echo "не удалось определить"; return; }
    printf '%s\n' "$ports" | paste -sd, -
}

ssh_confirm_close() {
    local port=$1 proto=$2 ports p lo hi matched=()
    [[ $proto == tcp || $proto == both ]] || return 0
    ports=$(ssh_ports) || { err "Не удалось определить порты SSH. Закрытие отменено."; return 1; }
    port=$(canonical_port "$port") || return 1
    lo=${port%:*}; hi=${port#*:}
    for p in $ports; do
        if (( p >= lo && p <= hi )); then matched+=("$p"); fi
    done
    (( ${#matched[@]} )) || return 0
    confirm_danger "Правило затрагивает порты SSH: ${matched[*]}. Удаление может закрыть доступ к серверу."
}

# ════════════════════════════════════════════════════════════════════════════
#  Единый слой UFW — им пользуются все модули, поэтому картина всегда сходится
# ════════════════════════════════════════════════════════════════════════════

ufw_ensure() {
    command -v ufw &>/dev/null && return 0
    warn "ufw не установлен."
    ask_yn "Установить ufw?" || return 1
    pkg_install ufw
}

# Именно "Status: active" целиком: подстрока "active" есть и в "inactive",
# из-за чего проверка раньше срабатывала всегда.
ufw_state() {
    local out
    command -v ufw &>/dev/null || { echo missing; return; }
    out=$(ufw status 2>/dev/null) || { echo unknown; return; }
    case ${out%%$'\n'*} in
        'Status: active') echo active ;;
        'Status: inactive') echo inactive ;;
        *) echo unknown ;;
    esac
}
ufw_active() { [[ $(ufw_state) == active ]]; }

# 10# — принудительно десятичная система: иначе bash считает 022 восьмеричным,
# а на 099 падает с "value too great for base".
valid_port() {  # порт или диапазон 8000:8100
    local v=$1 lo hi
    if [[ $v =~ ^[0-9]{1,5}$ ]]; then
        (( 10#$v >= 1 && 10#$v <= 65535 ))
        return
    fi
    if [[ $v =~ ^([0-9]{1,5}):([0-9]{1,5})$ ]]; then
        lo=${BASH_REMATCH[1]}; hi=${BASH_REMATCH[2]}
        (( 10#$lo >= 1 && 10#$hi <= 65535 && 10#$lo < 10#$hi ))
        return
    fi
    return 1
}

canonical_port() {
    valid_port "$1" || return 1
    if [[ $1 == *:* ]]; then printf '%s:%s\n' "$((10#${1%:*}))" "$((10#${1#*:}))"
    else printf '%s\n' "$((10#$1))"; fi
}

docker_port_selected() {
    local port=$1 proto=$2 key number lo=${1%%:*} hi=${1##*:}
    for key in "${!DOCKER_PORTS[@]}"; do
        [[ $proto == both || ${key#*/} == "$proto" ]] || continue
        number=${key%/*}
        if (( 10#$number >= 10#$lo && 10#$number <= 10#$hi )); then return 0; fi
    done
    return 1
}

# Адрес источника: одиночный IPv4 или подсеть. Проверяем сами, иначе ufw
# отвечает «Bad source address», не показывая, что именно ему не понравилось.
valid_source() {
    local v=$1 ip mask o
    if [[ $v == *:* ]]; then
        ip=${v%%/*}
        if [[ $v == */* ]]; then
            mask=${v#*/}
            [[ $mask =~ ^[0-9]{1,3}$ ]] && (( 10#$mask <= 128 )) || return 1
        fi
        [[ $ip =~ ^[0-9a-fA-F:]+$ && $ip != *:::* ]] || return 1
        local rest=${ip/::/X} groups=0
        [[ $rest != *::* ]] || return 1
        for o in ${ip//:/ }; do
            [[ $o =~ ^[0-9a-fA-F]{1,4}$ ]] || return 1
            groups=$((groups+1))
        done
        if [[ $ip == *::* ]]; then (( groups < 8 ))
        else [[ $ip != :* && $ip != *: ]] && (( groups == 8 )); fi
        return
    fi
    if [[ $v == */* ]]; then
        ip=${v%%/*}; mask=${v#*/}
        [[ $mask =~ ^[0-9]{1,2}$ ]] && (( 10#$mask <= 32 )) || return 1
    else
        ip=$v
    fi
    [[ $ip =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    for o in ${ip//./ }; do (( 10#$o <= 255 )) || return 1; done
    return 0
}

ufw_allow() {  # ufw_allow ПОРТ ПРОТО [IP] [limit|allow|route|docker]
    local port=$1 proto=$2 from_ip=${3:-} mode=${4:-allow} host=${5:-any}
    if [[ $mode == docker ]]; then
        ufw_docker_fix_applied || { err "Сначала настрой фильтрацию Docker в 5 → 1."; return 1; }
        docker_rule_add "$port" "$proto" "${from_ip:-any}" "$host"
        return
    fi
    case $mode in
        limit) run_quiet ufw limit "$port/$proto" ;;
        # Диапазон в ufw везде через двоеточие, включая route: замена на
        # дефис давала "Bad port '8000-8100'" и правило не создавалось.
        route) run_quiet ufw route allow proto "$proto" from "${from_ip:-any}" to any port "$port" ;;
        *)
            if [[ -n $from_ip ]]; then
                run_quiet ufw allow from "$from_ip" to any port "$port" proto "$proto"
            else
                run_quiet ufw allow "$port/$proto"
            fi
            ;;
    esac
}

# Номера правил, у которых колонка "To" — ровно наш порт.
# Сравниваем поле целиком, а не ищем число регуляркой по всей строке:
# иначе правило "8080/tcp ALLOW IN 192.168.1.22" удалялось при закрытии порта 22.
ufw_rule_numbers() {  # ufw_rule_numbers ПОРТ ПРОТО -> номера по убыванию
    local port=$1 proto=$2
    ufw status numbered 2>/dev/null \
        | sed -E 's/^\[[[:space:]]*([0-9]+)\][[:space:]]*/\1 /' \
        | awk -v a="$port/$proto" -v b="$port" '$1 ~ /^[0-9]+$/ && ($2 == a || $2 == b) {print $1}' \
        | sort -rn
}

# "ufw delete" выходит с кодом 0, даже когда правила не было, и печатает
# "Could not delete non-existent rule" — поэтому смотрим на вывод, а не на код.
ufw_del_try() {
    local out rc
    log "CMD: $*"
    out=$("$@" 2>&1); rc=$?
    [[ -n $out ]] && printf '%s\n' "$out" >>"$LOG_FILE"
    (( rc == 0 )) || return 1
    grep -qi "could not delete" <<<"$out" && return 1
    return 0
}

# Удаляет все варианты правила для порта: обычное, route и with-source.
ufw_delete_port() {
    local port=$1 proto=$2 removed=0 num rc
    port=$(canonical_port "$port") || return 1
    docker_rule_delete "$port" "$proto"; rc=$?
    case $rc in 0) removed=1 ;; 2) return 1 ;; esac
    if ! ufw_active; then
        warn "UFW выключен: список правил с номерами недоступен, поэтому правила"
        warn "с ограничением по источнику найти не получится. Включи UFW и повтори."
    fi
    ufw_del_try ufw delete allow "$port/$proto" && removed=1
    ufw_del_try ufw delete limit "$port/$proto" && removed=1
    ufw_del_try ufw route delete allow proto "$proto" from any to any port "$port" && removed=1
    # Остальное (правила с источником) — по номерам, обязательно снизу вверх,
    # иначе после первого удаления номера съезжают.
    while IFS= read -r num; do
        [[ -z $num ]] && continue
        # Без конвейера: "yes | ..." при pipefail отдаёт код 141 от SIGPIPE,
        # и успешное удаление выглядело как неудача.
        run_quiet ufw delete "$num" <<<"y" && removed=1
    done < <(ufw_rule_numbers "$port" "$proto")
    return $(( removed == 1 ? 0 : 1 ))
}

# Есть ли уже правило для порта. Работает и на выключенном UFW:
# "ufw show added" перечисляет добавленные правила независимо от статуса.
ufw_rule_exists() {  # ufw_rule_exists ПОРТ
    local p=$1
    ufw show added 2>/dev/null \
        | grep -qE "^ufw (route )?(allow|limit) (.*port )?${p}(/(tcp|udp))?( |$)"
}

declare -A UFW_MAP=()          # "порт/прото" -> ALLOW | LIMIT | DENY
ufw_load_map() {
    UFW_MAP=()
    command -v ufw &>/dev/null || return 0
    ufw_active || return 0
    local line out
    out=$(ufw status 2>/dev/null) || return 1
    while IFS= read -r line; do
        [[ $line =~ ^([0-9]+(:[0-9]+)?)/(tcp|udp)[[:space:]]+([A-Z]+) ]] && {
            UFW_MAP["${BASH_REMATCH[1]}/${BASH_REMATCH[3]}"]="${BASH_REMATCH[4]}"; continue; }
        # правило без протокола покрывает оба
        [[ $line =~ ^([0-9]+(:[0-9]+)?)[[:space:]]+([A-Z]+) ]] && {
            UFW_MAP["${BASH_REMATCH[1]}/tcp"]="${BASH_REMATCH[3]}"
            UFW_MAP["${BASH_REMATCH[1]}/udp"]="${BASH_REMATCH[3]}"; }
    done < <(printf '%s\n' "$out" | sed -e 's/(v6)//' -e 's/^ *//')
    # Пустая строка в конце ufw status не означает сбой чтения правил.
    return 0
}

ufw_lookup() {  # ufw_lookup порт прото -> ALLOW/LIMIT/"" (учитывает диапазоны)
    local port=$1 proto=$2 key lo hi
    if [[ -n ${UFW_MAP["$port/$proto"]:-} ]]; then echo "${UFW_MAP["$port/$proto"]}"; return; fi
    # дальше арифметика — на нечисловом порту она бы выдала ошибку bash
    [[ $port =~ ^[0-9]+$ ]] || { echo ""; return; }
    for key in "${!UFW_MAP[@]}"; do
        [[ $key == *"/$proto" ]] || continue
        [[ ${key%/*} == *:* ]] || continue
        lo=${key%%:*}; hi=${key#*:}; hi=${hi%/*}
        (( 10#$port >= 10#$lo && 10#$port <= 10#$hi )) && { echo "${UFW_MAP[$key]}"; return; }
    done
    echo ""
}

# Порты, которые нужно открыть, но UFW ещё не включён: их подхватит модуль
# Firewall, который в списке идёт последним. Так Portainer и смена порта SSH
# не теряют своё правило, если firewall настраивается в том же прогоне.
PENDING_PORTS=()

ufw_want() {  # ufw_want ПОРТ ПРОТО [allow|limit|route|docker]
    local port=$1 proto=$2 mode=${3:-allow}
    if [[ $(ufw_state) == unknown ]]; then err "Состояние UFW неизвестно; порт не изменён."; return 1; fi
    if command -v ufw &>/dev/null && ufw_active; then
        if ufw_allow "$port" "$proto" "" "$mode"; then
            ok "Порт $port/$proto разрешён в UFW."
            ufw_load_map
            return 0
        fi
        err "Не удалось открыть порт $port/$proto в UFW."
        return 1
    fi
    PENDING_PORTS+=("$port $proto $mode")
    warn "UFW сейчас неактивен — порт $port/$proto откроет модуль «Firewall»."
    return 0
}

ufw_flush_pending() {  # вызывается из модуля Firewall после включения UFW
    (( ${#PENDING_PORTS[@]} == 0 )) && return 0
    local entry port proto mode remaining=()
    for entry in "${PENDING_PORTS[@]}"; do
        read -r port proto mode <<<"$entry"
        if ufw_allow "$port" "$proto" "" "$mode"; then
            ok "Порт $port/$proto открыт (запрошен предыдущим модулем)."
        else
            err "Не удалось открыть $port/$proto."
            remaining+=("$entry")
        fi
    done
    PENDING_PORTS=("${remaining[@]}")
    (( ${#remaining[@]} == 0 ))
}

declare -A DOCKER_PORTS=()     # "порт/прото" -> 1  (опубликовано контейнером наружу)
docker_load_ports() {
    DOCKER_PORTS=()
    command -v docker &>/dev/null || return 0
    docker info &>/dev/null || return 1
    local line chunk output
    output=$(docker ps --format '{{.Ports}}' 2>/dev/null) || return 1
    # Регулярка в переменной: внутри [[ ]] голый ">" — это оператор сравнения,
    # а не часть шаблона, и разбор строки ломается.
    local re='^(.+):([0-9]+)->[0-9]+/(tcp|udp)$'
    while IFS= read -r line; do
        [[ -z $line ]] && continue
        while IFS= read -r chunk; do
            # 0.0.0.0:9443->9443/tcp  |  [::]:9443->9443/tcp  |  127.0.0.1:80->80/tcp
            [[ $chunk =~ $re ]] || continue
            local host=${BASH_REMATCH[1]} hport=${BASH_REMATCH[2]} hproto=${BASH_REMATCH[3]}
            [[ $host == 127.0.0.1 || $host == "[::1]" ]] && continue
            DOCKER_PORTS["$hport/$hproto"]=1
        done < <(printf '%s\n' "${line//, /$'\n'}")
    done <<<"$output"
}

ufw_docker_fix_applied() {
    grep -q '^# ubuntu-sh: original-destination$' "$UFW_AFTER4" 2>/dev/null &&
        grep -q '^# ubuntu-sh: original-destination$' "$UFW_AFTER6" 2>/dev/null
}

ufw_docker_block_remove() {
    local f
    for f in "$UFW_AFTER4" "$UFW_AFTER6"; do
        sed -i '/^# BEGIN UFW AND DOCKER$/,/^# END UFW AND DOCKER$/d' "$f" || return 1
    done
}

# ════════════════════════════════════════════════════════════════════════════
#  Менеджер портов (бывший portman.sh)
# ════════════════════════════════════════════════════════════════════════════

list_sockets() {  # proto|адрес|порт|процесс
    local raw
    if ! raw=$(ss -Htulnp 2>/dev/null); then
        raw=$(ss -tulnp 2>/dev/null) || return 1
        raw=$(tail -n +2 <<<"$raw")
    fi
    printf '%s\n' "$raw" | awk '
        NF >= 5 {
            proto = $1; loc = $5
            n = split(loc, a, ":"); port = a[n]
            addr = substr(loc, 1, length(loc) - length(port) - 1)
            # ss дописывает имя интерфейса: "127.0.0.53%lo". Для этой таблицы
            # оно ничего не решает — адрес и так помечается как localhost.
            sub(/%.*/, "", addr)
            if (addr == "") addr = "*"
            proc = "-"
            if (match($0, /"[^"]+"/))  proc = substr($0, RSTART+1, RLENGTH-2)
            if (match($0, /pid=[0-9]+/)) proc = proc "/" substr($0, RSTART+4, RLENGTH-4)
            print proto "|" addr "|" port "|" proc
        }' | awk '!seen[$0]++' | sort -t'|' -k3,3n
    # Дедупликация по всей строке, а не по ключу сортировки: иначе sort -u
    # выбросил бы IPv6-строку как «дубль» IPv4 с тем же номером порта.
}

is_localhost_addr() {
    [[ $1 == 127.* || $1 == "[::1]" || $1 == "::1" || $1 == "[::1]"* ]]
}

show_listening() {
    echo "${BLD}${CYN}── Слушающие сокеты ──────────────────────────────────────────${RST}"
    printf '%s %s %s %s\n' "$(pad ПРОТО 6)" "$(pad ПОРТ 7)" "$(pad АДРЕС 22)" "Состояние UFW"
    local proto addr port proc act cell state sockets
    state=$(ufw_state)
    sockets=$(list_sockets) || { err "Не удалось прочитать слушающие сокеты."; return 1; }
    while IFS='|' read -r proto addr port proc; do
        [[ -n $port ]] || continue
        if is_localhost_addr "$addr"; then cell="localhost"
        elif [[ $state != active ]]; then cell="UFW: $state"
        elif [[ -n ${DOCKER_PORTS["$port/$proto"]:-} ]]; then
            cell="Docker: $(docker_permission_summary "$port" "$proto")"
            docker_fix_live || cell+="; фильтрация не подтверждена"
        else
            act=$(ufw_lookup "$port" "$proto")
            cell="${act:-нет явного правила}; см. источник и политику"
        fi
        printf '%-6s %-7s %-22s %s\n' "$proto" "$port" "$addr" "$cell"
    done <<<"$sockets"
    echo "${DIM}Слушатель и правило не доказывают доступность с другой машины.${RST}"
    echo
}

show_ufw_rules() {
    echo "${BLD}${CYN}── Правила UFW ───────────────────────────────────────────────${RST}"
    if ! command -v ufw &>/dev/null; then
        echo "  ${YLW}ufw не установлен${RST}"; echo; return
    fi
    if ! ufw_active; then
        echo "  ${YLW}UFW: $(ufw_state). Фактическая доступность извне не проверена.${RST}"; echo; return
    fi
    local out
    # Заголовок ufw status numbered — четыре строки: статус, пустая,
    # "To Action From" и строка из дефисов. Срезаем все четыре.
    out=$(ufw status numbered 2>/dev/null | sed -e '1,4d' -e '/^$/d')
    if [[ -z $out ]]; then echo "  правил нет"; else printf '%s\n' "$out" | sed 's/^/  /'; fi
    if ufw_docker_fix_applied; then
        echo "  ${DIM}Разрешения Docker по внешнему порту (удаление через пункт 2):${RST}"
        if [[ -s $DOCKER_RULES ]]; then
            awk -F'|' '{ printf "    %s/%s  источник: %s  адрес сервера: %s\n", $1, $2, $3, $4 }' "$DOCKER_RULES"
        else echo "    нет разрешений"; fi
        docker_fix_live || warn "Работа фильтра Docker сейчас не подтверждена."
    fi
    echo
}

pm_open_port() {
    local port proto ip mode="allow" host=any failed=0
    ask "Порт (или диапазон, напр. 8000:8100)"; port=$REPLY_VAL
    valid_port "$port" || { err "Некорректный порт: получено «${port}»"; return 1; }
    port=$(canonical_port "$port") || return 1
    ask "Протокол [tcp/udp/both]" "tcp"; proto=$REPLY_VAL

    echo "${DIM}Пусто — с любого адреса. Иначе один адрес (192.168.10.174)"
    echo "или подсеть (192.168.10.0/24).${RST}"
    ask "Разрешить только с IP/подсети"; ip=$REPLY_VAL
    if [[ -n $ip ]] && ! valid_source "$ip"; then
        err "Непонятный адрес: $ip"
        err "Ожидается 192.168.10.174, 192.168.10.0/24 или пустая строка."
        return 1
    fi

    docker_load_ports
    docker_port_selected "$port" "$proto" && mode=docker
    if [[ $mode != docker ]] && command -v docker &>/dev/null &&
       ask_yn "Это порт контейнера Docker, который пока не запущен?"; then mode=docker; fi
    if [[ $mode == docker ]]; then
        ufw_docker_fix_applied || { err "Сначала настрой фильтрацию Docker в 5 → 1."; return 1; }
        ask "Адрес сервера для этого порта (Enter — все адреса)"; host=${REPLY_VAL:-any}
        [[ $host == any ]] || { [[ $host != */* ]] && valid_source "$host"; } || {
            err "Нужен IPv4/IPv6-адрес сервера."; return 1; }
        info "Разрешение для внешнего порта $port, адрес: $host."
    fi

    local p
    for p in $( [[ $proto == both ]] && echo "tcp udp" || echo "$proto" ); do
        [[ $p == tcp || $p == udp ]] || { err "Неверный протокол: $p"; return 1; }
        if ufw_allow "$port" "$p" "$ip" "$mode" "$host"; then
            ok "Разрешение $port/$p сохранено${ip:+ для $ip}."
        else
            err "Не удалось открыть $port/$p."
            failed=1
        fi
    done
    ufw_load_map
    return "$failed"
}

pm_close_port() {
    local port proto p
    ask "Порт (или диапазон)"; port=$REPLY_VAL
    valid_port "$port" || { err "Некорректный порт: получено «${port}»"; return 1; }
    ask "Протокол [tcp/udp/both]" "tcp"; proto=$REPLY_VAL

    ssh_confirm_close "$port" "$proto" || { info "Отменено."; return 0; }

    for p in $( [[ $proto == both ]] && echo "tcp udp" || echo "$proto" ); do
        [[ $p == tcp || $p == udp ]] || { err "Неверный протокол: $p"; continue; }
        if ufw_delete_port "$port" "$p"; then ok "Правила для $port/$p удалены."
        else warn "Правил для $port/$p не найдено."; fi
    done
    ufw_load_map
}

# Одна строка списка ufw без номера и пометки (v6): по ней ищется парное
# правило другого стека.
ufw_rule_body() {  # ufw_rule_body НОМЕР
    ufw status numbered 2>/dev/null \
        | sed -E 's/^\[[[:space:]]*([0-9]+)\][[:space:]]*/\1 /' \
        | awk -v n="$1" '$1 == n { $1=""; sub(/^ +/, ""); gsub(/\(v6\)/, ""); gsub(/  +/, " ");
                                   sub(/ +$/, ""); print }'
}

pm_delete_rule() {
    show_ufw_rules
    local num body twin
    # Намеренно по одному: списком легко снести опечаткой лишнее, а правила
    # после каждого удаления перенумеровываются.
    ask "Номер правила для удаления, по одному (Enter — отмена)"; num=$REPLY_VAL
    [[ -z $num ]] && return 0
    [[ $num =~ ^[0-9]+$ ]] || { err "Нужно одно число, получено «${num}»"; return 1; }

    # Логически правило одно, а ufw держит его двумя строками — для IPv4 и
    # IPv6. Удалять половину и оставлять вторую пользователю на разбор нельзя.
    body=$(ufw_rule_body "$num")

    if ! run_quiet ufw delete "$num" <<<"y"; then
        err "Не удалось удалить правило #$num."
        ufw_load_map
        return 1
    fi

    twin=""
    if [[ -n $body ]]; then
        twin=$(ufw status numbered 2>/dev/null \
               | sed -E 's/^\[[[:space:]]*([0-9]+)\][[:space:]]*/\1 /' \
               | awk -v b="$body" '{ n=$1; $1=""; sub(/^ +/, ""); gsub(/\(v6\)/, "");
                                     gsub(/  +/, " "); sub(/ +$/, "");
                                     if ($0 == b) { print n; exit } }')
    fi

    if [[ -n $twin ]] && run_quiet ufw delete "$twin" <<<"y"; then
        ok "Удалено правило #$num и парное к нему (второй стек, было #$twin)."
    else
        ok "Правило #$num удалено."
    fi
    ufw_load_map
}

pm_toggle_ufw() {
    if ufw_active; then
        confirm_danger "UFW будет выключен — весь входящий трафик станет разрешён." || return 0
        run_quiet ufw disable && ok "UFW выключен."
    else
        local ssh_p ports
        ports=$(ssh_ports) || { err "Не удалось определить порты SSH. UFW не включаю."; return 1; }
        # show added работает и на выключенном firewall.
        for ssh_p in $ports; do
            if ! ufw_rule_exists "$ssh_p"; then
                warn "Нет разрешения для порта SSH $ssh_p."
                ask_yn "Открыть порт $ssh_p/tcp перед включением?" || { info "UFW оставлен выключенным."; return 0; }
                ufw_allow "$ssh_p" tcp "" limit || return 1
                ok "Порт $ssh_p/tcp разрешён (limit)."
            fi
        done
        run_quiet ufw --force enable && ok "UFW включён."
    fi
    ufw_load_map
}

# "ufw reset" сносит не только правила: он выключает firewall и откатывает
# before/after.rules к заводским, унося вместе с ними блок Docker+UFW. Человек
# просил очистить правила, а не разнастроить машину, поэтому всё, что ставил
# сам скрипт, возвращаем обратно — восстанавливать руками нечего.
pm_reset_rules() {
    local was_active=0 had_fix=0 sshp ports line restore_failed=0
    local port proto source host extra
    local -a saved=()
    ufw_active && was_active=1
    ufw_docker_fix_applied && had_fix=1
    ports=$(ssh_ports) || { err "Не удалось определить порты SSH. Сброс отменён."; return 1; }

    # Реестр — список самого скрипта, в том числе для остановленных контейнеров.
    # Повторное открытие из docker ps теряло их и подставляло any/any.
    if [[ -f $DOCKER_RULES ]]; then
        while IFS= read -r line || [[ -n $line ]]; do
            [[ -n $line ]] && saved+=("$line")
        done <"$DOCKER_RULES"
    fi

    echo
    echo "${BLD}Будут удалены все правила${RST}, в том числе открытые тобой порты."
    echo "${DIM}Скрипт вернёт обратно то, что настраивал сам:${RST}"
    echo "  · правила для портов SSH ($(printf '%s\n' "$ports" | paste -sd, -))"
    if (( had_fix )); then
        echo "  · блок правил Docker+UFW в after.rules"
        if (( ${#saved[@]} )); then
            echo "  · разрешения Docker из реестра, с тем же источником и адресом:"
            printf '      %s\n' "${saved[@]}"
        fi
    fi
    (( was_active )) && echo "  · включённое состояние firewall"
    confirm_danger "Остальные правила восстановлены не будут." || return 0

    run_quiet ufw reset <<<"y" || { err "Сброс не выполнен."; return 1; }
    ok "Правила сброшены."

    if (( had_fix )); then
        # Сброс означает и удаление нашего отдельного списка разрешений.
        if [[ -f $DOCKER_RULES ]]; then backup_file "$DOCKER_RULES" >/dev/null || return 1; fi
        mkdir -p "${DOCKER_RULES%/*}" || return 1
        : >"$DOCKER_RULES" || return 1
        # После reset маркер в after.rules исчез, но известный нам фильтр
        # ещё может оставаться в ядре. Это восстановление, не чужая установка.
        # Пустой реестр коммитится здесь; непустой возвращается ниже построчно.
        docker_rules_commit "$DOCKER_RULES" || return 1
        if (( ${#saved[@]} )); then
            for line in "${saved[@]}"; do
                IFS='|' read -r port proto source host extra <<<"$line"
                if [[ -z $port || -z $proto || -z $source || -z $host || -n $extra ]]; then
                    err "Не вернулась строка реестра: $line"
                    restore_failed=1
                    continue
                fi
                # Тот же путь, что 3 → 1 → 1: фильтр Docker и правило host proxy.
                if ! docker_rule_add "$port" "$proto" "$source" "$host"; then
                    err "Не вернулась строка реестра: $line"
                    restore_failed=1
                fi
            done
        fi
    fi
    for sshp in $ports; do
        ufw_allow "$sshp" tcp "" limit || { err "Не удалось разрешить SSH $sshp; UFW оставлен выключенным."; return 1; }
    done
    if (( was_active )); then
        run_quiet ufw --force enable && ufw_active || return 1
        if (( had_fix )); then docker_fix_live || { err "Фильтр Docker после сброса не подтверждён."; return 1; }; fi
        ok "Firewall включён обратно."
    else
        info "Firewall остаётся выключенным — он и был выключен до сброса."
    fi
    ufw_load_map
    return "$restore_failed"
}

port_manager() {
    while true; do
        clear
        echo "${BLD}${BLU}╔══════════════════════════════════════════════════════════╗"
        echo "║              Порты и firewall (UFW)                      ║"
        echo "╚══════════════════════════════════════════════════════════╝${RST}"
        crumbs "Порты и firewall"
        echo
        command -v ufw &>/dev/null || { ufw_ensure || return 0; }
        ufw_load_map
        docker_load_ports
        show_listening
        show_ufw_rules

        echo "${BLD}Действия:${RST}"
        echo "  1) Открыть порт                4) Удалить правило по номеру"
        echo "  2) Закрыть порт                5) $(ufw_active && echo 'Выключить UFW' || echo 'Включить UFW')"
        echo "  3) Перезагрузить UFW           ${BLD}r${RST}) Сбросить все правила"
        echo "  0) Назад"
        echo
        local choice
        ask "Выбор"; choice=$REPLY_VAL
        case $choice in
            1) pm_open_port ;;
            2) pm_close_port ;;
            3) run_quiet ufw reload && ok "UFW перезагружен." ;;
            4) pm_delete_rule ;;
            5) pm_toggle_ufw ;;
            r|R|к|К) pm_reset_rules ;;
            0|q|Q) return 0 ;;
            *) err "Неверный выбор." ;;
        esac
        pause
    done
}

# ════════════════════════════════════════════════════════════════════════════
#  Модули установки и настройки
# ════════════════════════════════════════════════════════════════════════════

BASE_PACKAGES=(curl wget git vim mc htop tree jq rsync unzip zip net-tools
               bind9-dnsutils bash-completion ca-certificates gnupg)

mod_update() {
    apt_refresh || return 1
    info "Обновляю установленные пакеты..."
    run apt_get -y upgrade || return 1
    run_quiet apt_get -y --purge autoremove || true
    reboot_required && warn "После обновления системе требуется перезагрузка."
    return 0
}

mod_base() {
    local p installed=() missing=()
    for p in "${BASE_PACKAGES[@]}"; do
        if pkg_installed "$p"; then installed+=("$p"); else missing+=("$p"); fi
    done

    echo "${DIM}curl, wget — загрузка файлов      mc      — двухпанельный файловый менеджер"
    echo "git         — система контроля       vim     — редактор"
    echo "htop        — монитор процессов      tree    — дерево каталогов"
    echo "jq          — разбор JSON            rsync   — синхронизация файлов"
    echo "unzip, zip  — архивы                 net-tools — ifconfig, netstat, route"
    echo "bind9-dnsutils — dig, nslookup     bash-completion — дополнение по Tab"
    echo "ca-certificates, gnupg — сертификаты и подписи пакетов${RST}"
    echo

    if (( ${#installed[@]} )); then
        echo "${DIM}Уже стоят (${#installed[@]}): ${installed[*]}${RST}"
    fi
    if (( ${#missing[@]} == 0 )); then
        ok "Весь базовый набор уже установлен."
        ask_yn "Доставить что-то своё?" || return 0
    else
        echo "Будут установлены (${#missing[@]}): ${BLD}${missing[*]}${RST}"
        echo
        ask_yn "Установить этот набор?" && { pkg_install "${missing[@]}"; return; }
    fi

    ask "Свой список пакетов через пробел (Enter — пропустить)"
    [[ -z $REPLY_VAL ]] && { info "Ничего не устанавливаю."; return 0; }
    local custom=()
    read -r -a custom <<<"$REPLY_VAL"
    pkg_install "${custom[@]}"
}

mod_qemu() {
    local v; v=$(virt_type)
    if ! is_kvm_guest; then
        warn "Виртуализация: '${v}'. Это не KVM/QEMU-гость, агент здесь бесполезен."
        ask_yn "Всё равно установить qemu-guest-agent?" || { info "Пропускаю."; return 0; }
    else
        echo "Обнаружен гость $v — агент нужен для управления машиной из Proxmox."
    fi
    pkg_install qemu-guest-agent || return 1
    # Юнит статический: "enable" для него бессмыслен и печатает целую портянку
    # про отсутствие [Install]. Достаточно запустить.
    run_quiet systemctl start qemu-guest-agent && ok "qemu-guest-agent запущен."
}

mod_hostname() {
    local cur new
    cur=$(hostnamectl --static 2>/dev/null || hostname)
    echo "Текущее имя хоста: ${BLD}${cur}${RST}"
    ask "Новое имя (Enter — оставить как есть)"; new=$REPLY_VAL
    [[ -z $new || $new == "$cur" ]] && { info "Имя не меняю."; return 0; }
    if ! [[ $new =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]]; then
        err "Недопустимое имя хоста: получено «${new}»"
        err "Разрешены латинские буквы, цифры и дефис; дефис не в начале и не в конце."
        return 1
    fi
    # hostnamectl сам перепишет /etc/hostname, поэтому копию снимаем заранее:
    # без неё откат /etc/hosts вернул бы старое имя только наполовину.
    backup_file /etc/hostname >/dev/null
    run_quiet hostnamectl set-hostname "$new" || return 1
    # Строка 127.0.1.1 в /etc/hosts должна указывать на новое имя,
    # иначе sudo начинает подтормаживать на резолве.
    backup_file /etc/hosts >/dev/null
    if grep -qE '^127\.0\.1\.1' /etc/hosts; then
        sed -i -E "s/^(127\.0\.1\.1[[:space:]]+).*/\1${new}/" /etc/hosts
    else
        printf '127.0.1.1\t%s\n' "$new" >>/etc/hosts
    fi
    ok "Имя хоста: $cur → $new (в /etc/hosts тоже поправлено)."
    warn "В текущей сессии приглашение обновится после перелогина."
}

mod_time() {
    local cur ntp q n pick i
    local -a matches
    cur=$(timedatectl show -p Timezone --value 2>/dev/null || echo "?")
    ntp=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo "?")
    echo "Текущая таймзона: ${BLD}${cur}${RST}   Время: $(date '+%F %T')"
    if [[ $ntp == yes ]]; then
        echo "Синхронизация времени: ${GRN}включена${RST}"
    else
        echo "Синхронизация времени: ${YLW}нет${RST}"
    fi
    echo

    while true; do
        ask "Зона или часть названия (напр. Moscow; Enter — не менять)" "" free; q=$REPLY_VAL
        [[ -z $q ]] && break
        mapfile -t matches < <(timedatectl list-timezones 2>/dev/null | grep -i -- "$q")
        n=${#matches[@]}
        if (( n == 0 )); then echo "  ${YLW}Ничего не найдено.${RST}"; continue; fi

        local tz=""
        if (( n == 1 )); then
            # Одно совпадение — спрашивать номер бессмысленно, просто подтверждаем.
            if ask_yn "Найдено: ${BLD}${matches[0]}${RST}. Установить эту зону?"; then
                tz=${matches[0]}
            else
                continue
            fi
        else
            # Список листается по 25: при поиске вроде "euro" совпадений
            # шестьдесят, а показать «первые 25 и всё» — тупик.
            local page=0 per=25 from to again=0
            while true; do
                from=$(( page * per ))
                to=$(( from + per )); (( to > n )) && to=$n
                echo
                for (( i = from; i < to; i++ )); do
                    printf "  %2d) %s\n" "$((i+1))" "${matches[$i]}"
                done
                if (( n > per )); then
                    echo "  ${DIM}показано $((from+1))–$to из $n${RST}"
                    ask "Номер зоны · Enter — дальше · q — новый поиск"
                else
                    ask "Номер зоны (Enter — новый поиск)"
                fi
                pick=$REPLY_VAL
                if [[ -z $pick ]]; then
                    if (( n > per )); then
                        page=$(( (page + 1) % ((n + per - 1) / per) ))
                        continue
                    fi
                    again=1; break
                fi
                [[ $pick == [qQ] ]] && { again=1; break; }
                if ! pick=$(parse_uint "$pick" 1 "$n"); then
                    err "Неверный номер."; continue
                fi
                tz=${matches[$((pick-1))]}
                break
            done
            (( again )) && continue
        fi

        if run_quiet timedatectl set-timezone "$tz"; then
            ok "Таймзона: $tz"
        else
            err "Не удалось установить таймзону."
        fi
        break
    done

    echo
    if ask_yn "Включить синхронизацию времени (NTP)?"; then
        if run_quiet timedatectl set-ntp true; then ok "NTP включён."
        else warn "Не удалось включить NTP (нет systemd-timesyncd?)."; fi
    fi
    echo "Сейчас: $(date '+%F %T %Z')"
}

docker_log_rotation() {
    local f=/etc/docker/daemon.json size count tmp
    ask "Максимальный размер одного лог-файла" "10m"; size=$REPLY_VAL
    ask "Сколько файлов хранить на контейнер" "3"; count=$REPLY_VAL
    mkdir -p /etc/docker
    tmp=$(mktemp)
    if [[ -s $f ]] && command -v jq &>/dev/null; then
        if ! jq --arg s "$size" --arg c "$count" \
              '."log-driver"="json-file" | ."log-opts"=((."log-opts"//{}) + {"max-size":$s,"max-file":$c})' \
              "$f" >"$tmp" 2>/dev/null; then
            err "Не удалось разобрать $f — оставляю как есть."
            rm -f "$tmp"; return 1
        fi
    elif [[ -s $f ]]; then
        warn "$f уже существует, а jq не установлен — безопасно объединить не могу."
        rm -f "$tmp"; return 1
    else
        printf '{\n  "log-driver": "json-file",\n  "log-opts": { "max-size": "%s", "max-file": "%s" }\n}\n' \
            "$size" "$count" >"$tmp"
    fi
    [[ -f $f ]] && backup_file "$f" >/dev/null
    install -m 0644 "$tmp" "$f"; rm -f "$tmp"
    ok "Ротация логов Docker настроена ($size × $count)."
    if run_quiet systemctl restart docker; then ok "Docker перезапущен."
    else warn "Не удалось перезапустить Docker — проверь $f."; fi
    warn "Настройка действует на НОВЫЕ контейнеры; уже запущенные надо пересоздать."
}

DOCKER_RULES=/var/lib/ubuntu-sh/docker-ports
UFW_AFTER4=/etc/ufw/after.rules
UFW_AFTER6=/etc/ufw/after6.rules

# В реестре только внешние порты/адреса. IP контейнера после пересоздания
# меняется, а исходная точка назначения соединения остаётся той же.
docker_rule_valid() {
    local port=$1 proto=$2 source=$3 host=$4
    valid_port "$port" && [[ $proto == tcp || $proto == udp ]] || return 1
    [[ $source == any ]] || valid_source "$source" || return 1
    [[ $host == any ]] || { [[ $host != */* ]] && valid_source "$host"; } || return 1
    # Правило с IPv4-источником и IPv6-назначением никогда не совпадёт.
    if [[ $source != any && $host != any ]]; then
        [[ $source == *:* && $host == *:* || $source != *:* && $host != *:* ]] || return 1
    fi
}

docker_permission_summary() {
    local wanted=$1 protocol=$2 data port proto source host extra lo hi matches=""
    if ! data=$(cat "$DOCKER_RULES" 2>/dev/null); then
        echo "реестр разрешений недоступен"; return 0
    fi
    while IFS='|' read -r port proto source host extra; do
        [[ -n $port$proto$source$host$extra ]] || continue
        if [[ -n $extra ]] || ! docker_rule_valid "$port" "$proto" "$source" "$host"; then
            echo "реестр разрешений повреждён"; return 0
        fi
        [[ $proto == "$protocol" ]] || continue
        lo=${port%%:*}; hi=${port##*:}
        if (( 10#$wanted >= 10#$lo && 10#$wanted <= 10#$hi )); then
            matches+="${matches:+; }источник: $source, адрес сервера: $host"
        fi
    done <<<"$data"
    if [[ -n $matches ]]; then echo "разрешение есть в реестре скрипта ($matches)"
    else echo "разрешения нет в реестре скрипта"; fi
}

docker_rules_render() {  # семейство, реестр -> только ASCII для ufw
    local family=$1 registry=$2 port proto source host extra
    cat <<'RULES'
# BEGIN UFW AND DOCKER
# ubuntu-sh: original-destination
*filter
:DOCKER-USER - [0:0]
:UBUNTU-SH-DKR - [0:0]
-F DOCKER-USER
-F UBUNTU-SH-DKR
-A DOCKER-USER -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
-A DOCKER-USER -i docker+ -j RETURN
-A DOCKER-USER -i br-+ -j RETURN
-A DOCKER-USER -o docker+ -j UBUNTU-SH-DKR
-A DOCKER-USER -o br-+ -j UBUNTU-SH-DKR
-A DOCKER-USER -j RETURN
RULES
    while IFS='|' read -r port proto source host extra; do
        [[ -z $port ]] && continue
        [[ -z $extra ]] && docker_rule_valid "$port" "$proto" "$source" "$host" || return 1
        if [[ $family == 4 ]]; then
            [[ $source == *:* || $host == *:* ]] && continue
        else
            [[ $source != any && $source != *:* || $host != any && $host != *:* ]] && continue
        fi
        printf '%s' "-A UBUNTU-SH-DKR -p $proto -m conntrack --ctstate DNAT --ctdir ORIGINAL --ctorigdstport $port"
        [[ $source != any ]] && printf ' -s %s' "$source"
        [[ $host != any ]] && printf ' --ctorigdst %s' "$host"
        printf ' -j ACCEPT\n'
    done <"$registry"
    # Нет исключений по частным подсетям и высоким UDP-портам: локальная
    # сеть 172.16/12 тоже может быть внешним клиентом, а не контейнером.
    printf '%s\n' '-A UBUNTU-SH-DKR -j DROP' COMMIT '# END UFW AND DOCKER'
}

docker_fix_live() {
    ufw_active && ufw_docker_fix_applied || return 1
    docker_fix_supported >/dev/null 2>&1 || return 1
    # Наличие текста в after.rules не подтверждает работающий путь пакета.
    # Если UFW или иной firewall уже стоит перед Docker, не заявляем защиту.
    local rules
    rules=$(iptables -S FORWARD 2>/dev/null) || return 1
    [[ $(awk '$1 == "-A" { print; exit }' <<<"$rules") == '-A FORWARD -j DOCKER-USER' ]] || return 1
    iptables -C DOCKER-USER -o docker+ -j UBUNTU-SH-DKR 2>/dev/null &&
        iptables -C UBUNTU-SH-DKR -j DROP 2>/dev/null || return 1
    if grep -q . /proc/net/if_inet6 2>/dev/null; then
        ip6tables -C DOCKER-USER -o docker+ -j UBUNTU-SH-DKR 2>/dev/null &&
            ip6tables -C UBUNTU-SH-DKR -j DROP 2>/dev/null || return 1
        # При IPv6 userland-proxy пакет идёт в INPUT; при native IPv6 —
        # через DOCKER-USER. Если переход существует, проверяем его порядок.
        rules=$(ip6tables -S FORWARD 2>/dev/null) || return 1
        if grep -q -- '-j DOCKER-USER' <<<"$rules"; then
            [[ $(awk '$1 == "-A" { print; exit }' <<<"$rules") == '-A FORWARD -j DOCKER-USER' ]] || return 1
        fi
    fi
}

docker_fix_supported() {
    local backend ids id driver bridge
    command -v iptables &>/dev/null && command -v ip6tables &>/dev/null || {
        err "Нужны iptables/ip6tables из пакетов UFW."; return 1; }
    docker info &>/dev/null || { err "Docker не отвечает; фильтрацию не меняю."; return 1; }
    backend=$(docker info --format '{{.FirewallBackend}}' 2>/dev/null)
    [[ $backend != nftables ]] || { err "Docker с backend nftables пока не поддержан этим пунктом."; return 1; }
    iptables -C FORWARD -j DOCKER-USER 2>/dev/null || {
        err "Не найден рабочий переход Docker в DOCKER-USER. Фильтрацию не меняю."; return 1; }
    if grep -q . /proc/net/if_inet6 2>/dev/null && ! grep -qi '^IPV6=yes' /etc/default/ufw; then
        err "IPv6 работает, но выключен в UFW. Сначала согласуй настройки обоих стеков."; return 1
    fi
    ids=$(docker network ls -q --filter driver=bridge) || return 1
    for id in $ids; do
        bridge=$(docker network inspect --format '{{index .Options "com.docker.network.bridge.name"}}' "$id") || return 1
        case $bridge in ''|'<no value>'|docker*|br-*) ;; *)
            err "Нестандартный Docker bridge $bridge: автоматический фильтр для него не предусмотрен."; return 1 ;;
        esac
    done
}

docker_filter_clear() {
    local cmd
    for cmd in iptables ip6tables; do
        # Удалённый текст after.rules не удаляет уже загруженную цепочку.
        # Очищаем только узнаваемую схему этого скрипта.
        if "$cmd" -C DOCKER-USER -o docker+ -j UBUNTU-SH-DKR 2>/dev/null; then
            run_quiet "$cmd" -F DOCKER-USER || return 1
            run_quiet "$cmd" -A DOCKER-USER -j RETURN || return 1
            run_quiet "$cmd" -F UBUNTU-SH-DKR || return 1
            run_quiet "$cmd" -X UBUNTU-SH-DKR || return 1
        fi
    done
    return 0
}

docker_rules_loaded() {
    local registry=$1 family cmd expected line chain actual count args=()
    for family in 4 6; do
        # procfs reports zero file size even when IPv6 addresses exist.
        if [[ $family == 6 ]] && ! grep -q . /proc/net/if_inet6 2>/dev/null; then continue; fi
        if [[ $family == 4 ]]; then cmd=iptables; else cmd=ip6tables; fi
        expected=$(docker_rules_render "$family" "$registry") || return 1
        while IFS= read -r line; do
            [[ $line == '-A '* ]] || continue
            read -r -a args <<<"$line"
            "$cmd" -C "${args[@]:1}" 2>/dev/null || return 1
        done <<<"$expected"
        for chain in DOCKER-USER UBUNTU-SH-DKR; do
            actual=$("$cmd" -S "$chain" 2>/dev/null) || return 1
            count=$(awk -v c="$chain" '$1=="-A" && $2==c { n++ } END {print n+0}' <<<"$expected")
            [[ $(grep -c '^-A ' <<<"$actual") == "$count" ]] || return 1
        done
    done
}

docker_rules_commit() {  # реестр-кандидат; откатываем оба стека вместе
    local candidate=$1 dir f n=0 was=0 restore=0
    [[ -f $UFW_AFTER4 && -f $UFW_AFTER6 && ! -L $UFW_AFTER4 && ! -L $UFW_AFTER6 ]] || return 1
    case $(ufw_state) in active) was=1 ;; inactive) ;; *) err "Состояние UFW неизвестно."; return 1 ;; esac
    dir=$(mktemp -d) || return 1
    chmod 700 "$dir"
    for f in "$UFW_AFTER4" "$UFW_AFTER6"; do
        n=$((n+1))
        cp -a "$f" "$dir/$n.old" || return 1
        # Убираем пустой хвост перед добавлением блока: иначе каждый повтор
        # добавляет ещё одну пустую строку и создаёт «изменённую» копию.
        awk '
            /^# BEGIN UFW AND DOCKER$/ { block=1; next }
            /^# END UFW AND DOCKER$/ { block=0; next }
            block { next }
            { lines[++n]=$0; if ($0 ~ /[^[:space:]]/) last=n }
            END { for (i=1; i<=last; i++) print lines[i] }
        ' "$f" >"$dir/$n.new" || return 1
        printf '\n' >>"$dir/$n.new"
        docker_rules_render "$(( n == 1 ? 4 : 6 ))" "$candidate" >>"$dir/$n.new" || {
            err "Некорректная запись разрешений Docker. Файлы UFW не изменены."; return 1; }
    done
    if ! file_write "$UFW_AFTER4" <"$dir/1.new" || ! file_write "$UFW_AFTER6" <"$dir/2.new"; then
        restore=1
    elif (( was )) && { ! run_quiet ufw reload || ! docker_fix_live || ! docker_rules_loaded "$candidate"; }; then
        restore=1
    fi
    if (( restore == 0 )) && ! cmp -s -- "$candidate" "$DOCKER_RULES"; then
        mkdir -p "${DOCKER_RULES%/*}" || restore=1
        if [[ -f $DOCKER_RULES ]]; then backup_file "$DOCKER_RULES" >/dev/null || restore=1; fi
        if (( restore == 0 )); then
            # Переименование внутри каталога: сбой записи не оставляет
            # половину реестра при уже применённом наборе правил.
            local staged
            staged=$(mktemp "${DOCKER_RULES}.XXXXXX") || restore=1
            if (( restore == 0 )); then
                if ! cat "$candidate" >"$staged" || ! chmod 600 "$staged" || ! mv -f "$staged" "$DOCKER_RULES"; then restore=1; fi
            fi
        fi
    fi
    if (( restore )); then
        if (( was )); then docker_filter_clear || err "Не удалось очистить новый фильтр Docker при откате."; fi
        cp -a "$dir/1.old" "$UFW_AFTER4" && cp -a "$dir/2.old" "$UFW_AFTER6" || {
            err "Откат файлов не удался. Копии: $dir"; return 1; }
        if (( was )); then run_quiet ufw reload || err "Не удалось применить восстановленные правила UFW."; fi
        err "Новые правила не подтверждены; исходные файлы восстановлены. Копии: $dir"
        return 1
    fi
    rm -f "$dir/1.old" "$dir/2.old" "$dir/1.new" "$dir/2.new"
    rmdir "$dir" 2>/dev/null || true
    if (( was )); then ok "Правила Docker загружены и путь фильтрации проверен."
    else warn "Правила записаны. UFW выключен — фильтрация ещё не действует."; fi
}

docker_rule_add() {
    local port=$1 proto=$2 source=$3 host=$4 tmp line
    docker_rule_valid "$port" "$proto" "$source" "$host" || { err "Некорректное разрешение Docker."; return 1; }
    docker_fix_supported || return 1
    # Без ведущих нулей: сохранённое разрешение потом удаляется по тому же ключу.
    if [[ $port == *:* ]]; then port="$((10#${port%:*})):$((10#${port#*:}))"
    else port=$((10#$port)); fi
    tmp=$(mktemp) || return 1
    if [[ -f $DOCKER_RULES ]]; then cat "$DOCKER_RULES" >"$tmp" || return 1; fi
    line="$port|$proto|$source|$host"
    grep -Fxq -- "$line" "$tmp" || printf '%s\n' "$line" >>"$tmp"
    if ! docker_rules_commit "$tmp"; then rm -f "$tmp"; return 1; fi
    rm -f "$tmp"
    # IPv6 -> IPv4 userland-proxy — это INPUT, а не FORWARD. Такое же
    # ограничение источника/адреса добавляем для прокси на самом сервере.
    run_quiet ufw allow proto "$proto" from "$source" to "$host" port "$port" || {
        err "Docker-правило сохранено, но разрешение для host proxy не добавлено."; return 1; }
    if ufw_active; then docker_fix_live || { err "После изменения UFW фильтрация Docker не подтверждена."; return 1; }; fi
    return 0
}

docker_rule_delete() {
    local port=$1 proto=$2 tmp line tcol source host extra
    local -a gone=()
    port=$(canonical_port "$port") || return 2
    [[ -f $DOCKER_RULES ]] || return 1
    # Строки снимаем до очистки: после записи реестра их уже не из чего восстановить.
    while IFS= read -r line; do
        [[ -n $line ]] && gone+=("$line")
    done < <(awk -F'|' -v p="$port" -v t="$proto" '$1==p && $2==t { print }' "$DOCKER_RULES")
    (( ${#gone[@]} )) || return 1
    ufw_docker_fix_applied || { err "Фильтр Docker отсутствует; сначала восстанови его в 5 → 1."; return 2; }
    tmp=$(mktemp) || return 2
    awk -F'|' -v p="$port" -v t="$proto" '!($1==p && $2==t)' "$DOCKER_RULES" >"$tmp" || { rm -f "$tmp"; return 2; }
    if ! docker_rules_commit "$tmp"; then rm -f "$tmp"; return 2; fi
    rm -f "$tmp"
    # Номерной поиск UFW сравнивает только поле «To». Правило на адрес
    # сервера записано как «10.0.0.5 8080/tcp», и закрытие порта его не видело.
    # Снимаем ту же команду, которой правило добавлялось. Если её уже нет,
    # закрытие порта всё равно завершаем: фильтр Docker уже записан.
    for line in "${gone[@]}"; do
        IFS='|' read -r _ tcol source host extra <<<"$line"
        [[ -z $extra && -n $tcol && -n $source && -n $host ]] || continue
        ufw_del_try ufw delete allow proto "$tcol" from "$source" to "$host" port "$port" || true
    done
    return 0
}

apply_ufw_docker_fix() {
    docker_fix_supported || return 1
    # Чужие DOCKER-USER правила нельзя затереть своим блоком. Старый блок
    # ubuntu.sh заменяем явно, а обычные route-правила больше не используем
    # для обхода запрета: они сопоставляют внутренний, а не внешний порт.
    local rules tmp
    rules=$(iptables -S DOCKER-USER 2>/dev/null) || return 1
    if ! grep -q '^# BEGIN UFW AND DOCKER$' "$UFW_AFTER4" 2>/dev/null &&
       grep -q '^-A ' <<<"$rules"; then
        if [[ $(grep '^-A ' <<<"$rules") != '-A DOCKER-USER -j RETURN' ]]; then
            err "В DOCKER-USER есть чужие правила. Автоматическая замена отменена."; return 1
        fi
    fi
    tmp=$(mktemp) || return 1
    if [[ -f $DOCKER_RULES ]]; then cat "$DOCKER_RULES" >"$tmp" || return 1; fi
    if ! docker_rules_commit "$tmp"; then rm -f "$tmp"; return 1; fi
    rm -f "$tmp"
    warn "Разрешения контейнеров показаны отдельно в 3 → 1. Старые route-правила их не заменяют."
}

mod_docker() {
    if command -v docker &>/dev/null; then
        ok "Docker уже установлен: $(docker --version 2>/dev/null)"
    else
        pkg_install curl ca-certificates || return 1
        info "Ставлю Docker через официальный скрипт get.docker.com..."
        local tmp; tmp=$(mktemp)
        if ! run_quiet curl -fsSL https://get.docker.com -o "$tmp"; then
            err "Не удалось скачать установщик Docker."; rm -f "$tmp"; return 1
        fi
        run sh "$tmp" || { err "Установка Docker не удалась."; rm -f "$tmp"; return 1; }
        rm -f "$tmp"
    fi

    # get.docker.com ставит пакеты сам, минуя pkg_install, и в манифест они не
    # попадали — числились «поставленными не скриптом». Отмечаем и при первой
    # установке, и при повторном заходе на уже настроенной машине.
    local d dk=()
    for d in docker-ce docker-ce-cli docker-ce-rootless-extras containerd.io \
             docker-buildx-plugin docker-compose-plugin docker-model-plugin; do
        pkg_installed "$d" && dk+=("$d")
    done
    (( ${#dk[@]} )) && { CURRENT_MODULE="Docker"; manifest_add "${dk[@]}"; }
    run_quiet systemctl enable --now docker || { err "Не удалось запустить службу docker."; return 1; }

    if [[ $TARGET_USER != root ]]; then
        if id -nG "$TARGET_USER" 2>/dev/null | grep -qw docker; then
            echo "${DIM}  $TARGET_USER уже в группе docker${RST}"
        elif ask_yn "Добавить пользователя $TARGET_USER в группу docker (работа без sudo)?"; then
            run_quiet usermod -aG docker "$TARGET_USER" \
                && warn "Готово. Перелогинься под $TARGET_USER, чтобы применилось."
        fi
    fi

    echo
    if [[ -s /etc/docker/daemon.json ]] && grep -q "max-size" /etc/docker/daemon.json 2>/dev/null; then
        ok "Ротация логов Docker уже настроена."
    else
        echo "${DIM}По умолчанию логи контейнеров не ограничены: болтливый контейнер"
        echo "может за месяц занять десятки гигабайт в /var/lib/docker.${RST}"
        ask_yn "Настроить ротацию логов Docker?" && docker_log_rotation
    fi

    echo
    if ufw_docker_fix_applied; then
        if docker_fix_live; then ok "Фильтр Docker+UFW загружен."
        else warn "Файлы фильтра есть, но работа фильтрации сейчас не подтверждена."; fi
    else
        echo "${YLW}${BLD}Важно:${RST} ${YLW}Docker пишет правила напрямую в iptables, в обход UFW."
        echo "Контейнер, запущенный с -p 8080:80, доступен из сети, даже если"
        echo "ufw status показывает, что порт закрыт. Фикс добавляет блок правил"
        echo "в /etc/ufw/after.rules и after6.rules. Разрешения задаются по внешнему порту —"
        echo "и из интернета, и из локальной сети. Между собой контейнеры"
        echo "продолжают общаться свободно.${RST}"
        # Показываем поимённо, что именно перестанет отвечать: без списка
        # предупреждение бесполезно, особенно если скрипт запускают через год.
        docker_load_ports
        local pub=() k
        for k in "${!DOCKER_PORTS[@]}"; do pub+=("$k"); done
        if (( ${#pub[@]} )); then
            echo
            echo "${BLD}Сейчас контейнеры публикуют наружу:${RST}"
            printf '  %s\n' "${pub[@]}"
            echo "${DIM}Прежние разрешения сохранятся. Остальные порты можно разрешить после фикса.${RST}"
        fi

        if ask_yn "Применить фикс?"; then
            confirm_danger "После фикса порты без сохранённых разрешений будут фильтроваться. Проверь список выше." || return 0
            ufw_ensure && apply_ufw_docker_fix || return 1
            if (( ${#pub[@]} )); then
                if ask_yn "Разрешить эти порты заново прямо сейчас?"; then
                    for k in "${pub[@]}"; do ufw_want "${k%/*}" "${k#*/}" docker || return 1; done
                else
                    info "Новые разрешения для ${pub[*]} не добавлены. Прежние разрешения сохранены."
                    info "Открыть порт можно в 3 → 1 → 1; проверить разрешения — в 6 → 2."
                fi
            fi
        else
            info "Пропускаю. Помни: опубликованные порты сейчас смотрят наружу мимо UFW."
        fi
    fi
}

# Portainer не умеет обновлять сам себя: образ надо стянуть заново и
# пересоздать контейнер. Тома portainer_data это не трогает, настройки и
# пользователи остаются на месте.
# Portainer блокирует себя, если администратора не завели в первые пять минут
# после запуска: панель показывает «Your Portainer instance timed out for
# security purposes». Лечится перезапуском контейнера, данные не теряются.
portainer_restart() {
    info "Перезапускаю контейнер portainer..."
    if run_quiet docker restart portainer; then
        ok "Перезапущен. Открой ${BLD}https://$(primary_ip):9443${RST} и заведи администратора."
        warn "На это снова даётся около пяти минут — не откладывай."
    else
        err "Не удалось перезапустить контейнер."
        return 1
    fi
}

portainer_menu() {
    echo "  1) Проверить обновление"
    echo "  2) Перезапустить контейнер ${DIM}(если панель пишет «timed out»)${RST}"
    echo "  0) Ничего не делать"
    local c
    ask "Выбор"; c=$REPLY_VAL
    case $c in
        1) portainer_update ;;
        2) portainer_restart ;;
        *) info "Оставляю как есть." ;;
    esac
}

portainer_update() {
    local cur new args=() p mounts bindings target host published
    cur=$(docker inspect --format '{{.Image}}' portainer 2>/dev/null) || {
        err "Не удалось прочитать конфигурацию Portainer."; return 1; }
    [[ -n $cur ]] || { err "Не удалось определить текущий образ Portainer."; return 1; }

    # Фиксированный docker run ниже безопасен только для наших подключений.
    # Иной /data нельзя молча заменить пустым томом, а дополнительные mounts — потерять.
    mounts=$(docker inspect --format '{{range .Mounts}}{{printf "%s|%s|%s|%s|%t\n" .Type .Name .Source .Destination .RW}}{{end}}' portainer 2>/dev/null) || {
        err "Не удалось проверить подключения Portainer."; return 1; }
    local data_count=0 socket_count=0 type name source dest rw
    while IFS='|' read -r type name source dest rw; do
        [[ -z $type ]] && continue
        if [[ $type == volume && $name == portainer_data && $dest == /data && $rw == true ]]; then
            data_count=$((data_count+1))
        elif [[ $type == bind && $source == /var/run/docker.sock && $dest == /var/run/docker.sock && $rw == true ]]; then
            socket_count=$((socket_count+1))
        else
            err "Нестандартное подключение Portainer: $dest. Автообновление отменено."; return 1
        fi
    done <<<"$mounts"
    if (( data_count != 1 || socket_count != 1 )); then
        err "Ожидались том portainer_data в /data и /var/run/docker.sock. Автообновление отменено."
        return 1
    fi

    # docker port теряет настройки остановленного контейнера. Inspect хранит
    # исходные адреса, включая localhost и IPv6: без них панель открывалась наружу.
    bindings=$(docker inspect --format '{{range $port, $bindings := .HostConfig.PortBindings}}{{range $bindings}}{{printf "%s|%s|%s\n" $port .HostIp .HostPort}}{{end}}{{end}}' portainer 2>/dev/null) || {
        err "Не удалось прочитать публикации портов Portainer."; return 1; }
    while IFS='|' read -r target host published; do
        [[ -z $target ]] && continue
        if ! [[ $target =~ ^[0-9]+/(tcp|udp)$ && $published =~ ^[0-9]+$ ]]; then
            err "Не удалось сохранить публикацию $target. Автообновление отменено."; return 1
        fi
        [[ $host == *:* && $host != \[*\] ]] && host="[$host]"
        p="${published}:${target}"
        [[ -n $host ]] && p="${host}:$p"
        args+=(-p "$p")
    done <<<"$bindings"
    if (( ${#args[@]} == 0 )); then
        err "Нет явных публикаций портов Portainer. Автообновление нестандартной установки отменено."
        return 1
    fi

    echo "${DIM}Обновление: стягивается свежий образ и контейнер пересоздаётся."
    echo "Данные лежат в томе portainer_data и не затрагиваются.${RST}"

    info "Тяну свежий образ..."
    run docker pull portainer/portainer-ce:latest || { err "Не удалось скачать образ."; return 1; }
    new=$(docker inspect --format '{{.Id}}' portainer/portainer-ce:latest 2>/dev/null) || return 1
    [[ -n $new ]] || { err "Не удалось определить новый образ Portainer."; return 1; }

    if [[ -n $cur && $cur == "$new" ]]; then
        ok "Уже последняя версия — пересоздавать нечего."
        return 0
    fi
    ok "Образ latest отличается от образа текущего контейнера."

    confirm_danger "Контейнер portainer будет остановлен и пересоздан. Панель будет недоступна несколько секунд." || return 0

    run_quiet docker stop portainer || true
    run_quiet docker rm portainer   || { err "Не удалось удалить старый контейнер."; return 1; }
    if ! run docker run -d "${args[@]}" \
            --name portainer --restart=always \
            -v /var/run/docker.sock:/var/run/docker.sock \
            -v portainer_data:/data \
            portainer/portainer-ce:latest; then
        err "Новый контейнер не запустился. Старый образ ещё в системе:"
        err "  docker run -d ${args[*]} --name portainer --restart=always \\"
        err "    -v /var/run/docker.sock:/var/run/docker.sock -v portainer_data:/data $cur"
        return 1
    fi
    ok "Portainer обновлён и запущен."
    if ask_yn "Удалить старый образ, чтобы не занимал место?"; then
        run_quiet docker image prune -f >/dev/null && ok "Неиспользуемые образы удалены."
    fi
}

PORTAINER_URL=""
PORTAINER_EDGE=0
mod_portainer() {
    command -v docker &>/dev/null || { err "Docker не установлен — Portainer ставить некуда."; return 1; }
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx portainer; then
        ok "Контейнер portainer уже существует."
        portainer_menu
    else
        local edge_args=()
        echo "${DIM}Порт 8000 нужен только для Edge-агентов; для веб-панели на 9443 — нет.${RST}"
        if ask_yn "Публиковать порт 8000 (Edge-агенты)?"; then
            edge_args=(-p 8000:8000)
            PORTAINER_EDGE=1
        fi
        run_quiet docker volume create portainer_data || true
        if ! run docker run -d "${edge_args[@]}" -p 9443:9443 \
                --name portainer --restart=always \
                -v /var/run/docker.sock:/var/run/docker.sock \
                -v portainer_data:/data \
                portainer/portainer-ce:latest; then
            err "Не удалось запустить Portainer."; return 1
        fi
        ok "Portainer запущен."
        echo
        echo "${YLW}${BLD}Не откладывай:${RST} ${YLW}открой панель и заведи администратора"
        echo "в ближайшие ${BLD}пять минут${RST}${YLW}. Если не успеть, Portainer закроет"
        echo "себя из соображений безопасности и напишет «timed out» —"
        echo "тогда его надо перезапустить этим же пунктом меню (данные целы).${RST}"
    fi
    # ufw_want сам решит: открыть сейчас или передать модулю Firewall,
    # если UFW ещё не включён (он в списке идёт позже).
    ufw_want 9443 tcp docker || return 1
    if (( PORTAINER_EDGE )); then ufw_want 8000 tcp docker || return 1; fi
    PORTAINER_URL="https://$(primary_ip):9443"
    echo "Панель: ${BLD}${PORTAINER_URL}${RST}"
}

# Меняет порт ТОЛЬКО в секции [sshd]. Простой sed по "port =" переписал бы
# порты во всех jail'ах файла, включая чужие.
f2b_set_ssh_port() {
    local newp=$1 jail=/etc/fail2ban/jail.local tmp
    [[ -f $jail ]] || return 0
    grep -q '^\[sshd\]' "$jail" || { warn "В $jail нет секции [sshd] — порт не меняю."; return 0; }
    backup_file "$jail" >/dev/null
    tmp=$(mktemp)
    awk -v p="$newp" '
        /^\[/ { sec = $0 }
        sec == "[sshd]" && /^[[:space:]]*port[[:space:]]*=/ { print "port    = " p; next }
        { print }
    ' "$jail" >"$tmp" || { rm -f "$tmp"; err "Не смог обновить $jail."; return 1; }
    cat "$tmp" >"$jail"; rm -f "$tmp"
    if run_quiet systemctl restart fail2ban; then
        ok "fail2ban переключён на порт $newp."
    else
        warn "fail2ban не перезапустился — смотри journalctl -u fail2ban."
    fi
}

f2b_show_current() {
    echo "  Сейчас в файле задано (по секциям, без отдельных строк комментариев):"
    # Выборка четырёх ключей из DEFAULT скрывала настройки отдельных jail,
    # action и многострочный ignoreip. Показываем все непустые строки как есть,
    # не выдавая текст одного файла за итоговую конфигурацию службы.
    awk '
        /^[[:space:]]*([#;]|$)/ { next }
        { print "    " $0; n++ }
        END { if (!n) print "    Явных настроек нет." }
    ' "$1"
}

mod_fail2ban() {
    pkg_install fail2ban || return 1
    local jail=/etc/fail2ban/jail.local sshp ports
    ports=$(ssh_ports) || { err "Не удалось определить порты SSH. Jail не меняю."; return 1; }
    sshp=$(printf '%s\n' "$ports" | paste -sd, -)
    if [[ -f $jail ]]; then
        warn "$jail уже есть."
        echo "  Этот файл задаёт, за какими службами следить, сколько неудачных"
        echo "  входов терпеть, на сколько банить и чьи адреса не банить никогда."
        echo
        f2b_show_current "$jail" || { err "Не удалось прочитать $jail; замена отменена."; return 1; }
        echo
        echo "  В новом файле: jail sshd, порт $sshp, бан 1h после 5 попыток за 10m."
        echo "  ignoreip: только 127.0.0.1/8 и ::1; backend: systemd."
        echo "  Всё остальное из этого файла пропадёт. jail.conf и jail.d не меняются,"
        echo "  но их параметры могут перекрываться новым файлом или перекрывать его."
        echo
        echo "  Копия сохраняется перед заменой: $BACKUP_DIR"
        echo "  Вернуть — пункт 7 → 4 «Восстановить файл из резервной копии»."
        echo
        if ! ask_yn "Перезаписать?"; then
            run_quiet systemctl enable --now fail2ban
            info "Оставляю текущий конфиг."
            return 0
        fi
    fi
    # На Ubuntu 24.04 нет /var/log/auth.log — логи только в journald,
    # поэтому backend=systemd, иначе jail молча не работает.
    file_write "$jail" <<EOF || return 1
[DEFAULT]
backend  = systemd
bantime  = 1h
findtime = 10m
maxretry = 5
ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled = true
port    = $sshp
EOF
    ok "Написан $jail (jail sshd включён, порт $sshp)."
    run_quiet systemctl enable fail2ban || true
    if run_quiet systemctl restart fail2ban; then
        sleep 1
        if run_quiet fail2ban-client status sshd >/dev/null; then
            ok "fail2ban работает, jail sshd активен."
        else
            warn "fail2ban запущен, но jail sshd не отвечает — смотри journalctl -u fail2ban."
        fi
    else
        err "fail2ban не запустился — смотри journalctl -u fail2ban."
        return 1
    fi
}

unattended_on() {
    grep -qE '^[[:space:]]*APT::Periodic::Unattended-Upgrade[[:space:]]+"1"' \
        /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null
}

unattended_reboot_on() {
    grep -qiE '^[[:space:]]*Unattended-Upgrade::Automatic-Reboot[[:space:]]+"true"' \
        /etc/apt/apt.conf.d/52unattended-upgrades-local 2>/dev/null
}

unattended_off() {
    confirm_danger "Обновления безопасности перестанут устанавливаться сами." || return 0
    file_write /etc/apt/apt.conf.d/20auto-upgrades <<'EOF' || return 1
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Unattended-Upgrade "0";
EOF
    run_quiet systemctl disable --now unattended-upgrades || true
    ok "Автообновления выключены. Ставить их теперь только вручную."
}

mod_unattended() {
    echo "${DIM}Автоматическая установка обновлений безопасности (только -security;"
    echo "обычные пакеты сами обновляться не будут).${RST}"

    # Раньше модуль умел только включать: ответ «нет» просто пропускал его,
    # и выключить автообновления через скрипт было нельзя.
    if unattended_on; then
        local reb="выключена"
        unattended_reboot_on && reb="в 04:00"
        echo "Сейчас: ${GRN}включены${RST}, автоперезагрузка ${BLD}${reb}${RST}"
        echo "  1) Изменить настройку автоперезагрузки"
        echo "  2) Выключить автообновления"
        echo "  0) Ничего не менять"
        local c
        ask "Выбор"; c=$REPLY_VAL
        case $c in
            1) ;;                     # ниже спросим про перезагрузку
            2) unattended_off; return ;;
            *) info "Оставляю как есть."; return 0 ;;
        esac
    else
        ask_yn "Включить автообновления безопасности?" || { info "Пропускаю."; return 0; }
    fi

    pkg_install unattended-upgrades || return 1
    file_write /etc/apt/apt.conf.d/20auto-upgrades <<'EOF' || return 1
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
    local rc=/etc/apt/apt.conf.d/52unattended-upgrades-local
    if ask_yn "Автоматически перезагружаться в 04:00, если обновление этого требует?"; then
        file_write "$rc" <<'EOF' || return 1
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-WithUsers "false";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
EOF
        ok "Автоперезагрузка в 04:00 включена (только если никто не залогинен)."
    else
        file_write "$rc" <<'EOF' || return 1
Unattended-Upgrade::Automatic-Reboot "false";
EOF
        ok "Автоперезагрузка выключена."
    fi
    run_quiet systemctl enable --now unattended-upgrades || true
    ok "Автообновления безопасности включены."
}

mod_logs() {
    local d=/etc/systemd/journald.conf.d f size
    f="$d/99-ubuntu-sh.conf"
    echo "Журнал сейчас занимает: ${BLD}$(journal_usage)${RST}"
    echo "${DIM}По умолчанию journald может занять до 10% раздела — на диске 500 ГБ это 50 ГБ логов.${RST}"
    ask "Ограничить размер журнала (Enter — применить 500M, «-» — не менять)" "500M"; size=$REPLY_VAL
    [[ -z $size || $size == "-" ]] && { info "Лимит не меняю."; return 0; }
    # Регистр суффикса не важен: "100m" приводим к виду, который понимает systemd
    size=${size^^}
    if ! [[ $size =~ ^[0-9]+[KMGT]$ ]]; then
        err "Формат: число с суффиксом K, M, G или T. Например 100M или 2G."; return 1
    fi
    mkdir -p "$d"
    # SystemMaxFileSize намеренно не задаём: по умолчанию systemd берёт одну
    # восьмую от SystemMaxUse — ровно то, что нужно, и без краевых случаев.
    file_write "$f" <<EOF || return 1
[Journal]
SystemMaxUse=$size
EOF
    run_quiet systemctl restart systemd-journald || warn "Не удалось перезапустить systemd-journald."
    ok "Лимит журнала: $size (файл $f)."
    if ask_yn "Сжать журнал до нового лимита прямо сейчас?"; then
        run journalctl --vacuum-size="$size" || true
    fi
}

# ════════════════════════════════════════════════════════════════════════════
#  Диски: расширение корня (LVM и обычный раздел)
# ════════════════════════════════════════════════════════════════════════════

ROOT_SRC=""; ROOT_FS=""; ROOT_IS_LVM=0; ROOT_VG=""
ROOT_PVS=()

disk_probe() {
    ROOT_SRC=$(findmnt -no SOURCE / 2>/dev/null)
    ROOT_FS=$(findmnt -no FSTYPE / 2>/dev/null)
    ROOT_IS_LVM=0; ROOT_VG=""; ROOT_PVS=()
    [[ -z $ROOT_SRC ]] && return 1
    # На btrfs findmnt возвращает "/dev/sda2[/@]" — подтом в скобках лишний.
    ROOT_SRC=${ROOT_SRC%%[[]*}
    [[ -b $ROOT_SRC ]] || return 1
    if [[ $(lsblk -no TYPE "$ROOT_SRC" 2>/dev/null | head -1) == lvm ]]; then
        ROOT_IS_LVM=1
        ROOT_VG=$(lvs --noheadings -o vg_name "$ROOT_SRC" 2>/dev/null | tr -d ' ')
        local p vg
        while read -r p vg; do
            [[ -n $p && $vg == "$ROOT_VG" ]] && ROOT_PVS+=("$p")
        done < <(pvs --noheadings -o pv_name,vg_name 2>/dev/null)
    fi
    return 0
}

# Свободное ли место на диске ПОСЛЕ последнего раздела.
# Сравнивать размер диска с размером одного раздела нельзя: на диске обычно
# есть ещё EFI и /boot, и разница будет ненулевой всегда.
# Печатает "диск|свободно_байт", возвращает 1, если места нет.
disk_tail_free() {  # disk_tail_free /dev/sdaX
    local part=$1 disk total_sec last_end free_sec
    disk="/dev/$(lsblk -no PKNAME "$part" 2>/dev/null | head -1)"
    [[ -b $disk ]] || return 1
    command -v partx &>/dev/null || return 1
    total_sec=$(blockdev --getsz "$disk" 2>/dev/null) || return 1
    last_end=$(partx -g -o END "$disk" 2>/dev/null | tr -d ' ' | sort -n | tail -1)
    [[ $total_sec =~ ^[0-9]+$ && $last_end =~ ^[0-9]+$ ]] || return 1
    free_sec=$(( total_sec - last_end - 1 ))
    # меньше 16 МБ — считаем, что расширять нечего
    (( free_sec > 32768 )) || return 1
    printf '%s|%s\n' "$disk" "$(( free_sec * 512 ))"
}

human_size() { numfmt --to=iec "$1" 2>/dev/null || echo "${1} Б"; }

# vgs при нулевом свободном месте печатает "0", а не "0g", поэтому сравниваем
# численно, а не со строкой.
vg_free_gb() { vgs --noheadings --nosuffix --units g -o vg_free "$1" 2>/dev/null | tr -d ' <'; }
vg_has_free() {
    local f; f=$(vg_free_gb "$1")
    [[ -n $f ]] || return 1
    awk -v v="$f" 'BEGIN { exit !(v + 0 > 0.01) }'
}

ensure_growpart() {
    command -v growpart &>/dev/null && return 0
    info "Нужна утилита growpart (пакет cloud-guest-utils)."
    pkg_install cloud-guest-utils
}

grow_partition() {  # grow_partition /dev/sda3
    local part=$1 disk num
    disk="/dev/$(lsblk -no PKNAME "$part" 2>/dev/null | head -1)"
    num=$(echo "$part" | grep -oE '[0-9]+$')
    [[ -b $disk && -n $num ]] || { err "Не смог определить диск/номер раздела для $part."; return 1; }
    ensure_growpart || return 1
    info "Расширяю раздел $part на диске $disk..."
    if run growpart "$disk" "$num"; then
        run_quiet partprobe "$disk" 2>/dev/null || true
        ok "Раздел $part расширен."
        return 0
    fi
    warn "growpart не расширил раздел (возможно, свободного места уже нет)."
    return 1
}

grow_root_fs() {
    case $ROOT_FS in
        ext2|ext3|ext4) run resize2fs "$ROOT_SRC" ;;
        xfs)            run xfs_growfs / ;;
        btrfs)          run btrfs filesystem resize max / ;;
        *)              err "Не знаю, как расширять ФС '$ROOT_FS'."; return 1 ;;
    esac
}

disk_show() {
    disk_probe || { err "Не смог определить корневое устройство."; return 1; }
    echo "${BLD}${CYN}── Корень ─────────────────────────────────────────────${RST}"
    df -hT / | sed 's/^/  /'
    echo "  устройство: ${BLD}$ROOT_SRC${RST}   ФС: $ROOT_FS   тип: $( ((ROOT_IS_LVM)) && echo LVM || echo "обычный раздел")"
    echo
    if (( ROOT_IS_LVM )); then
        echo "${BLD}${CYN}── LVM ────────────────────────────────────────────────${RST}"
        vgs --units g -o vg_name,vg_size,vg_free 2>/dev/null | sed 's/^/  /'
        echo
        lvs --units g -o lv_path,vg_name,lv_size 2>/dev/null | sed 's/^/  /'
        echo
        echo "  PV группы $ROOT_VG: ${ROOT_PVS[*]:-?}"
    fi
    echo
    echo "${BLD}${CYN}── Диски и разделы ────────────────────────────────────${RST}"
    lsblk -o NAME,SIZE,FSTYPE,TYPE,MOUNTPOINTS 2>/dev/null | sed 's/^/  /' \
        || lsblk | sed 's/^/  /'
    echo
    local tgt pv
    if (( ROOT_IS_LVM )); then
        for pv in "${ROOT_PVS[@]}"; do
            if tgt=$(disk_tail_free "$pv"); then
                warn "На диске ${tgt%%|*} свободно $(human_size "${tgt##*|}") после раздела $pv — пункт 2."
            fi
        done
        if vg_has_free "$ROOT_VG"; then
            warn "В группе $ROOT_VG свободно $(vg_free_gb "$ROOT_VG")g — пункт 3."
        fi
    else
        if tgt=$(disk_tail_free "$ROOT_SRC"); then
            warn "На диске ${tgt%%|*} свободно $(human_size "${tgt##*|}") после раздела — пункт 2."
        fi
    fi
}

disk_grow_pv() {
    (( ROOT_IS_LVM )) || { err "Корень не на LVM."; return 1; }
    (( ${#ROOT_PVS[@]} )) || { err "Не определил физические тома."; return 1; }

    local pv=${ROOT_PVS[0]} i choice tgt
    # В группе может быть несколько физических томов — спрашиваем, какой растить.
    if (( ${#ROOT_PVS[@]} > 1 )); then
        echo "В группе $ROOT_VG несколько физических томов:"
        i=1
        for pv in "${ROOT_PVS[@]}"; do
            if tgt=$(disk_tail_free "$pv"); then
                printf "  %d) %-16s свободно на диске: %s\n" "$i" "$pv" "$(human_size "${tgt##*|}")"
            else
                printf "  %d) %-16s %s\n" "$i" "$pv" "свободного места на диске нет"
            fi
            i=$((i+1))
        done
        ask "Номер тома (Enter — отмена)"; choice=$REPLY_VAL
        [[ -z $choice ]] && return 0
        if ! choice=$(parse_uint "$choice" 1 "${#ROOT_PVS[@]}"); then
            err "Неверный номер: получено «${REPLY_VAL}»"; return 1
        fi
        pv=${ROOT_PVS[$((choice-1))]}
    fi

    confirm_danger "Раздел $pv будет расширен на всё свободное место диска, затем pvresize. Сделай снапшот, если его ещё нет." || return 0
    grow_partition "$pv" || return 1
    run pvresize "$pv" || { err "pvresize не прошёл."; return 1; }
    ok "Физический том расширен. Теперь можно расширить LV (пункт 3)."
    disk_probe
}

disk_grow_lv() {
    (( ROOT_IS_LVM )) || { err "Корень не на LVM."; return 1; }
    local free
    free=$(vg_free_gb "$ROOT_VG")
    echo "Свободно в группе $ROOT_VG: ${BLD}${free:-?}g${RST}"
    if ! vg_has_free "$ROOT_VG"; then
        warn "Свободного места в VG нет. Сначала расширь PV (пункт 2)."
        return 0
    fi
    # Снять после живого прохода: проверен только рост LV на ext4.
    if [[ $ROOT_FS != ext4 ]]; then
        warn "Этот вариант на живой машине не проверен."
    fi
    confirm_danger "Логический том $ROOT_SRC и файловая система на нём будут расширены на всё свободное место VG." || return 0
    if run lvextend -r -l +100%FREE "$ROOT_SRC"; then
        ok "Готово."
    else
        warn "lvextend -r не справился, пробую расширить ФС отдельно."
        run lvextend -l +100%FREE "$ROOT_SRC" || { err "lvextend не прошёл."; return 1; }
        grow_root_fs || return 1
    fi
    df -hT / | sed 's/^/  /'
}

disk_grow_plain() {
    (( ROOT_IS_LVM )) && { err "Корень на LVM — используй пункты 2 и 3."; return 1; }
    # Снять после живого прохода: вариант без LVM не проверялся.
    warn "Этот вариант на живой машине не проверен."
    confirm_danger "Раздел $ROOT_SRC и файловая система будут расширены на всё свободное место диска." || return 0
    grow_partition "$ROOT_SRC" || return 1
    grow_root_fs || return 1
    ok "Готово."
    df -hT / | sed 's/^/  /'
}

mod_disk() {
    disk_probe || { err "Не смог определить корневое устройство."; return 1; }
    while true; do
        crumbs "Диски"
        disk_show
        echo "${BLD}Действия:${RST}"
        echo "  1) Обновить сведения"
        if (( ROOT_IS_LVM )); then
            echo "  2) Расширить физический том на весь диск (growpart + pvresize)"
            echo "  3) Расширить корневой LV на всё свободное место VG (+ ФС)"
        else
            echo "  2) Расширить корневой раздел и ФС на весь диск (growpart + resize)"
        fi
        echo "  0) Готово, дальше"
        local c
        ask "Выбор"; c=$REPLY_VAL
        case $c in
            1) disk_probe ;;
            2) if (( ROOT_IS_LVM )); then disk_grow_pv; else disk_grow_plain; fi; pause ;;
            3) if (( ROOT_IS_LVM )); then disk_grow_lv; pause; else err "Нет такого пункта."; fi ;;
            0|q|Q|"") return 0 ;;
            *) err "Неверный выбор." ;;
        esac
    done
}

# ════════════════════════════════════════════════════════════════════════════
#  Swap
# ════════════════════════════════════════════════════════════════════════════

swap_show() {
    echo "${BLD}${CYN}── Swap ───────────────────────────────────────────────${RST}"
    if [[ -n $(swapon --show --noheadings 2>/dev/null) ]]; then
        swapon --show 2>/dev/null | sed 's/^/  /'
    else
        echo "  ${YLW}swap не активен${RST}"
    fi
    echo
    free -h | sed 's/^/  /'
    echo
    echo "  vm.swappiness = ${BLD}$(cat /proc/sys/vm/swappiness 2>/dev/null || echo '?')${RST}   ${DIM}(0 — избегать swap, 60 — по умолчанию, 100 — активно)${RST}"
    echo
}

swap_file_path() {  # текущий своп-файл, если он есть
    swapon --show=NAME,TYPE --noheadings 2>/dev/null \
        | awk '$2=="file"{print $1; exit}'
}

swap_create() {
    local cur path size mem_gb
    cur=$(swap_file_path)
    mem_gb=$(awk '/MemTotal/{printf "%d", ($2/1024/1024)+0.5}' /proc/meminfo 2>/dev/null)
    ask "Путь к своп-файлу" "${cur:-/swapfile}"; path=$REPLY_VAL
    [[ -z $path ]] && return 0
    ask "Размер в гигабайтах (RAM ≈ ${mem_gb}G)" "$(( mem_gb < 2 ? 2 : mem_gb ))"; size=$REPLY_VAL
    size=$(parse_uint "$size" 1 2147483647) || { err "Нужно целое число гигабайт: получено «${REPLY_VAL}»"; return 1; }

    # Дальше будет rm -f по этому пути, поэтому проверяем ввод придирчиво.
    [[ $path == /* ]] || { err "Нужен абсолютный путь, например /swapfile."; return 1; }
    case $path in
        /|/etc/*|/usr/*|/bin/*|/sbin/*|/lib/*|/boot/*|/dev/*|/proc/*|/sys/*|/run/*|*/)
            err "Путь $path в системном каталоге — здесь своп-файл создавать не буду."
            return 1 ;;
    esac
    if [[ -e $path && ! -f $path ]]; then
        err "$path существует и это не обычный файл. Отказываюсь его трогать."
        return 1
    fi

    local is_swap=0
    swapon --show=NAME --noheadings 2>/dev/null | grep -qx "$path" && is_swap=1
    if [[ -e $path ]]; then
        if (( is_swap )); then
            confirm_danger "Своп-файл $path будет отключён и пересоздан размером ${size}G." || return 0
        else
            confirm_danger "Файл $path СУЩЕСТВУЕТ и своп-файлом не является ($(du -h "$path" 2>/dev/null | cut -f1)). Он будет УДАЛЁН и заменён своп-файлом ${size}G." || return 0
        fi
    fi
    if (( is_swap )); then
        run_quiet swapoff "$path" || { err "Не удалось отключить $path."; return 1; }
    fi
    rm -f "$path"

    info "Создаю $path размером ${size}G..."
    if ! run_quiet fallocate -l "${size}G" "$path"; then
        warn "fallocate не сработал (btrfs/ФС без поддержки) — создаю через dd, это дольше."
        run dd if=/dev/zero of="$path" bs=1M count=$((size * 1024)) status=progress \
            || { err "Не удалось создать файл."; return 1; }
    fi
    chmod 600 "$path"
    run_quiet mkswap "$path" || { err "mkswap не прошёл."; return 1; }
    run_quiet swapon "$path" || { err "swapon не прошёл."; return 1; }

    # fstab: убираем старую запись для этого пути и добавляем свежую
    backup_file /etc/fstab >/dev/null
    sed -i "\\%^[[:space:]]*${path}[[:space:]]%d" /etc/fstab
    printf '%s none swap sw 0 0\n' "$path" >>/etc/fstab
    ok "Своп-файл $path (${size}G) создан, включён и прописан в /etc/fstab."
}

swap_remove() {
    local path
    path=$(swap_file_path)
    [[ -z $path ]] && { warn "Активного своп-файла нет (раздел swap этот пункт не трогает)."; return 0; }
    confirm_danger "Своп-файл $path будет отключён, удалён и убран из /etc/fstab." || return 0
    run_quiet swapoff "$path" || { err "Не удалось отключить $path."; return 1; }
    backup_file /etc/fstab >/dev/null
    sed -i "\\%^[[:space:]]*${path}[[:space:]]%d" /etc/fstab
    rm -f "$path"
    ok "Своп-файл удалён."
}

swap_swappiness() {
    local v cur f=/etc/sysctl.d/99-swappiness.conf
    cur=$(cat /proc/sys/vm/swappiness 2>/dev/null || echo 60)
    # Пустой ввод — не трогать: иначе Enter молча создаёт файл заново.
    ask "Значение vm.swappiness (0-100), Enter — оставить $cur"; v=$REPLY_VAL
    [[ -z $v ]] && { info "Оставляю $cur."; return 0; }
    v=$(parse_uint "$v" 0 100) || { err "Нужно число от 0 до 100: получено «${REPLY_VAL}»"; return 1; }
    file_write "$f" <<<"vm.swappiness = $v" || return 1
    run_quiet sysctl -w "vm.swappiness=$v" >/dev/null
    ok "vm.swappiness = $v (постоянно: $f)."
}

zram_active() { swapon --show=NAME --noheadings 2>/dev/null | grep -q '^/dev/zram'; }

zram_off() {
    confirm_danger "zram будет отключён, служба zramswap выключена." || return 0
    run_quiet systemctl disable --now zramswap || warn "Служба zramswap не остановилась."
    zram_active && run_quiet swapoff /dev/zram0
    ok "zram выключен."
    if ask_yn "Удалить пакет zram-tools?"; then
        run apt_get purge -y zram-tools && ok "Пакет удалён."
    fi
}

swap_zram() {
    echo "${DIM}zram — сжатый swap прямо в оперативной памяти. Полезен на VM с небольшой RAM:"
    echo "вместо обращения к диску страницы сжимаются и остаются в памяти.${RST}"

    if zram_active || pkg_installed zram-tools; then
        if zram_active; then
            echo "Сейчас zram ${GRN}включён${RST}: $(swapon --show=NAME,SIZE --noheadings 2>/dev/null | grep zram | tr -s ' ')"
        else
            echo "Пакет zram-tools установлен, но zram сейчас не активен."
        fi
        echo "  1) Изменить долю RAM"
        echo "  2) Выключить zram"
        echo "  0) Ничего не менять"
        local c
        ask "Выбор"; c=$REPLY_VAL
        case $c in
            1) ;;                       # ниже спросим процент
            2) zram_off; return ;;
            *) info "Оставляю как есть."; return 0 ;;
        esac
    else
        ask_yn "Установить и включить zram?" || return 0
        pkg_install zram-tools || return 1
    fi

    local pct cur_pct
    cur_pct=$(awk -F= '/^[[:space:]]*PERCENT=/{print $2}' /etc/default/zramswap 2>/dev/null | tr -d '[:space:]' | tail -1)
    ask "Сколько процентов RAM отдать под zram" "${cur_pct:-25}"; pct=$REPLY_VAL
    pct=$(parse_uint "$pct" 1 90) || { err "Нужно число 1-90: получено «${REPLY_VAL}»"; return 1; }
    if [[ -f /etc/default/zramswap ]]; then
        backup_file /etc/default/zramswap >/dev/null
        sed -i -E "s/^#?[[:space:]]*PERCENT=.*/PERCENT=$pct/" /etc/default/zramswap
        grep -q '^PERCENT=' /etc/default/zramswap || printf 'PERCENT=%s\n' "$pct" >>/etc/default/zramswap
    else
        printf 'PERCENT=%s\n' "$pct" >/etc/default/zramswap
    fi
    run_quiet systemctl enable zramswap || true
    # После выключения через пункт 2 служба остаётся disabled — включаем обратно
    run_quiet systemctl enable zramswap || true
    if run_quiet systemctl restart zramswap; then ok "zram включён ($pct% RAM)."
    else warn "Служба zramswap не запустилась — смотри journalctl -u zramswap."; fi
}

mod_swap() {
    while true; do
        crumbs "Swap"
        swap_show
        echo "${BLD}Действия:${RST}"
        echo "  1) Создать / пересоздать своп-файл"
        echo "  2) Удалить своп-файл"
        echo "  3) Изменить vm.swappiness"
        echo "  4) zram (сжатый swap в RAM)"
        echo "  0) Готово, дальше"
        local c
        ask "Выбор"; c=$REPLY_VAL
        case $c in
            1) swap_create; pause ;;
            2) swap_remove; pause ;;
            3) swap_swappiness; pause ;;
            4) swap_zram; pause ;;
            0|q|Q|"") return 0 ;;
            *) err "Неверный выбор." ;;
        esac
    done
}

# ════════════════════════════════════════════════════════════════════════════
#  IPv6
# ════════════════════════════════════════════════════════════════════════════

ipv6_state() {
    local scope value zero=0 one=0
    for scope in all default lo; do
        value=$(sysctl -n "net.ipv6.conf.$scope.disable_ipv6" 2>/dev/null) || { echo unknown; return; }
        case $value in
            0) zero=$((zero+1)) ;;
            1) one=$((one+1)) ;;
            *) echo unknown; return ;;
        esac
    done
    if (( zero == 3 )); then echo enabled
    elif (( one == 3 )); then echo disabled
    else echo mixed; fi
}
ipv6_disabled() { [[ $(ipv6_state) == disabled ]]; }

mod_ipv6() {
    local f=/etc/sysctl.d/99-disable-ipv6.conf state target
    state=$(ipv6_state)
    case $state in
        enabled) target=1 ;;
        disabled) target=0 ;;
        mixed)
            warn "Параметры IPv6 различаются для all/default/lo."
            ask "Привести к одному состоянию [on/off], Enter — отмена"
            case $REPLY_VAL in on) target=0 ;; off) target=1 ;; *) return 0 ;; esac ;;
        *) err "Не удалось прочитать состояние IPv6. Настройки не меняю."; return 1 ;;
    esac
    if (( target == 0 )); then
        echo "IPv6 сейчас: ${YLW}отключён${RST}"
        ask_yn "Включить IPv6 обратно?" || { info "Оставляю как есть."; return 0; }
        local removed=0
        if [[ -e $f || -L $f ]]; then
            if [[ ! -L $f ]] && file_owned "$f"; then
                backup_file "$f" >/dev/null || return 1
                file_manifest_del "$f" || return 1
                rm -f "$f" || return 1
                removed=1
            else
                # Файл мог написать администратор, и сносить его молча нельзя.
                # Но и отказ без выхода не годится: в манифест он уже никогда
                # не попадёт, и IPv6 останется выключенным навсегда. Поэтому
                # файл не трогаем как целое, а гасим в нём сами параметры.
                [[ -L $f ]] && { err "$f — символическая ссылка, не трогаю."; return 1; }
                warn "$f создан не этим скриптом — удалять его не буду."
                if ! ask_yn "Сохранить копию и заменить в нём disable_ipv6 на 0?"; then
                    info "Оставляю как есть."; return 0
                fi
                backup_file "$f" >/dev/null || return 1
                local re='^([[:space:]]*net\.ipv6\.conf\.[A-Za-z0-9_.-]+\.disable_ipv6[[:space:]]*=[[:space:]]*)1[[:space:]]*$'
                sed -i -E "s|$re|\\10|" "$f" || { err "Не удалось изменить $f."; return 1; }
            fi
        fi
        run_quiet sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null
        run_quiet sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null
        run_quiet sysctl -w net.ipv6.conf.lo.disable_ipv6=0 >/dev/null
        run_quiet sysctl --system >/dev/null
        # Отключение может возвращать и другой файл в sysctl.d, поэтому смотрим
        # фактическое значение, а не считаем, что раз команды прошли — готово.
        if [[ $(ipv6_state) != enabled ]]; then
            err "Включение IPv6 не подтверждено для all/default/lo."
            err "Искать так: grep -rs disable_ipv6 /etc/sysctl.conf /etc/sysctl.d /usr/lib/sysctl.d"
            return 1
        fi
        if (( removed )); then ok "IPv6 включён (файл $f удалён)."
        else                   ok "IPv6 включён (all/default/lo проверены)."
        fi
    else
        echo "IPv6 сейчас: ${GRN}включён${RST}"
        ask_yn "Отключить IPv6?" || { info "Оставляю как есть."; return 0; }
        file_write "$f" <<'EOF' || return 1
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
        run_quiet sysctl --system >/dev/null
        [[ $(ipv6_state) == disabled ]] || { err "Отключение IPv6 не подтверждено — проверь $f и другие файлы в sysctl.d."; return 1; }
        ok "IPv6 отключён (файл $f)."
        echo "${DIM}После перезагрузки сетевой менеджер может вернуть IPv6 на интерфейс:"
        echo "sysctl применяется раньше, чем поднимается линк. Проверить —"
        echo "главное меню, пункт «Проверка безопасности».${RST}"
    fi
}

# sysctl.d применяется рано, а systemd-networkd потом поднимает интерфейс и
# возвращает на нём IPv6 обратно. Сразу после применения расхождения ещё нет
# (запись в all проставляет 1 и существующим линкам) — оно вылезает только
# после перезагрузки, поэтому проверка живёт в разделе безопасности.
# Netplan не правим: ошибка в нём отрезает машину, а «netplan try» с откатом
# пользователь должен запустить осознанно.
ipv6_check_interfaces() {
    local dev val bad=()
    [[ -d /sys/class/net ]] || return 0
    for dev in /sys/class/net/*; do
        [[ -e $dev ]] || continue
        dev=${dev##*/}
        # Интерфейсы докера, мостов и виртуальных пар netplan не ведёт —
        # советовать по ним правку netplan бессмысленно.
        case $dev in
            lo|docker*|br-*|veth*|virbr*|tap*|tun*|cni*|flannel*) continue ;;
        esac
        val=$(sysctl -n "net.ipv6.conf.$dev.disable_ipv6" 2>/dev/null)
        [[ $val == 0 ]] && bad+=("$dev")
    done
    (( ${#bad[@]} )) || return 0

    echo
    warn "На интерфейсах ${bad[*]} IPv6 остался включён."
    echo "${DIM}Настройку из sysctl.d перебивает сетевой менеджер: он поднимает"
    echo "интерфейс позже и заново включает на нём IPv6. Остаётся адрес fe80::"
    echo "— link-local, наружу он не маршрутизируется, но выключенным IPv6"
    echo "это назвать нельзя.${RST}"
    local cfg found=0
    for dev in "${bad[@]}"; do
        # Ищем файл, в котором объявлен именно этот интерфейс
        cfg=$(grep -lE "^[[:space:]]+${dev}:[[:space:]]*$" /etc/netplan/*.yaml /etc/netplan/*.yml 2>/dev/null | head -1)
        [[ -n $cfg ]] || continue
        found=1
        echo
        echo "Чтобы убрать и его, открой ${BLD}${cfg}${RST} и добавь две строки"
        echo "в блок интерфейса ${BLD}${dev}${RST}. Сейчас он такой:"
        echo
        netplan_show_block "$cfg" "$dev" ""
        echo
        echo "Должен стать таким:"
        echo
        netplan_show_block "$cfg" "$dev" "add"
    done

    if (( found )); then
        echo
        echo "Отступы обязательны, YAML их считает. Применяй через ${BLD}sudo netplan try${RST}"
        echo "— он откатится сам через две минуты, если связь оборвётся."
        echo "${DIM}Скрипт netplan не правит намеренно: опечатка в нём отрезает машину.${RST}"
    else
        echo
        warn "Блок интерфейса в /etc/netplan/ не найден — сеть настроена не через netplan."
    fi
}

# Печатает блок интерфейса из netplan как есть. С аргументом "add" дописывает
# в конец блока две строки на том же отступе, что и остальные его параметры.
netplan_show_block() {
    local file=$1 dev=$2 mode=$3
    awk -v dev="$dev" -v mode="$mode" -v cyn="$CYN" -v dim="$DIM" -v rst="$RST" '
        function indent(s,   n) { match(s, /^[ ]*/); return RLENGTH }
        $0 ~ "^[ ]+" dev ":[ ]*$" { inblk = 1; base = indent($0); print "  " $0; next }
        inblk {
            if ($0 ~ /^[ ]*$/) { next }
            if (indent($0) <= base) {
                inblk = 0
                if (mode == "add") emit()
                next
            }
            if (!child) { child = indent($0) }
            print "  " $0
            next
        }
        END { if (inblk && mode == "add") emit() }
        function emit(   pad, i) {
            pad = ""
            for (i = 0; i < (child ? child : base + 2); i++) pad = pad " "
            print "  " pad cyn "accept-ra: false" rst "      " dim "← добавлено" rst
            print "  " pad cyn "link-local: []" rst "        " dim "← добавлено" rst
        }
    ' "$file"
}

# ════════════════════════════════════════════════════════════════════════════
#  SSH
# ════════════════════════════════════════════════════════════════════════════

SSHD_DROPIN=""
sshd_target_file() {
    if [[ -n $SSHD_DROPIN ]]; then echo "$SSHD_DROPIN"; return; fi
    if grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config 2>/dev/null; then
        # Имя начинается с 00 не случайно: в sshd_config выигрывает ПЕРВОЕ
        # вхождение параметра, а файлы каталога читаются по алфавиту. Ubuntu
        # кладёт туда 50-cloud-init.conf с "PasswordAuthentication yes", и
        # файл с именем 99-… проигрывал ему молча.
        SSHD_DROPIN=/etc/ssh/sshd_config.d/00-ubuntu-sh.conf
        mkdir -p /etc/ssh/sshd_config.d
        # переносим настройки из прежнего имени, если оно осталось
        if [[ -f /etc/ssh/sshd_config.d/99-ubuntu-sh.conf && ! -f $SSHD_DROPIN ]]; then
            # Перенос старого имени не доказывает, что файл создал этот скрипт.
            file_manifest_del "$SSHD_DROPIN" || return 1
            mv /etc/ssh/sshd_config.d/99-ubuntu-sh.conf "$SSHD_DROPIN" || return 1
        fi
    else
        SSHD_DROPIN=/etc/ssh/sshd_config
    fi
    echo "$SSHD_DROPIN"
}

sshd_set() {  # sshd_set Ключ Значение
    local key=$1 val=$2 f tmp
    f=$(sshd_target_file) || return 1
    if [[ $f == /etc/ssh/sshd_config ]]; then
        backup_file "$f" >/dev/null
        # закомментировать прежние объявления, чтобы не спорили с нашим
        sed -i -E "s/^([[:space:]]*${key}[[:space:]].*)$/#\1/I" "$f"
        printf '%s %s\n' "$key" "$val" >>"$f"
    else
        tmp=$(mktemp) || return 1
        if grep -qiE "^[[:space:]]*${key}[[:space:]]" "$f" 2>/dev/null; then
            sed -E "s|^[[:space:]]*${key}[[:space:]].*|${key} ${val}|I" "$f" >"$tmp" || { rm -f "$tmp"; return 1; }
        else
            if [[ -f $f ]]; then
                cat "$f" >"$tmp" || { rm -f "$tmp"; return 1; }
            else
                printf '# Created by ubuntu.sh\n' >"$tmp"
            fi
            printf '\n%s %s\n' "$key" "$val" >>"$tmp"
        fi
        if ! file_write "$f" 0600 <"$tmp"; then rm -f "$tmp"; return 1; fi
        rm -f "$tmp"
    fi
}

sshd_apply() {  # проверить конфиг и перезапустить
    if ! sshd -t &>/dev/null; then
        err "Конфигурация sshd содержит ошибку — НЕ перезапускаю службу."
        sshd -t 2>&1 | sed 's/^/  /'
        err "Поправь $(sshd_target_file). Резервные копии: $BACKUP_DIR."
        return 1
    fi
    # Пароли и ключи не требуют смены слушателя. Reload сохраняет сессии;
    # отдельная процедура смены порта проверяет также сам слушающий сокет.
    if ssh_socket_enabled && ! systemctl is-active --quiet ssh.service; then
        ok "Конфигурация SSH проверена; служба прочитает её при подключении."
        return 0
    fi
    run_quiet systemctl reload ssh.service || { err "Не удалось перечитать SSH."; return 1; }
    ok "Настройки SSH перечитаны."
}

ssh_key_files() {  # печатает "пользователь:путь:кол-во ключей"
    local u home f n
    while IFS=: read -r u _ uid _ _ home _; do
        (( uid == 0 || uid >= 1000 )) || continue
        [[ $u == nobody ]] && continue
        [[ -d $home ]] || continue
        f="$home/.ssh/authorized_keys"
        if [[ -f $f ]]; then
            n=$(grep -cvE "^[[:space:]]*(#|$)" "$f" 2>/dev/null); n=${n:-0}
        else
            n=0
        fi
        printf '%s:%s:%s\n' "$u" "$f" "$n"
    done </etc/passwd
}

local_users() {  # печатает "имя:uid:домашний каталог:sudo" для root и обычных учёток
    # sudo: 1 — в группе sudo, 0 — нет, ? — группу прочитать не удалось.
    local accounts group rc sgid members name uid gid home s
    accounts=$(getent -s files passwd) || return 1
    group=$(getent -s files group sudo); rc=$?
    IFS=: read -r _ _ sgid members <<<"$group"
    while IFS=: read -r name _ uid gid _ home _; do
        [[ $uid =~ ^[0-9]+$ ]] || continue
        (( 10#$uid == 0 || (10#$uid >= 1000 && 10#$uid != 65534) )) || continue
        [[ $name == nobody ]] && continue
        if (( rc != 0 && rc != 2 )); then s='?'
        elif [[ ,$members, == *",$name,"* || ( -n $sgid && $gid == "$sgid" ) ]]; then s=1
        else s=0; fi
        printf '%s:%s:%s:%s\n' "$name" "$uid" "$home" "$s"
    done <<<"$accounts"
}

users_brief() {  # справка перед вводом имени: "root, anton (sudo), bob"
    local list name s out=""
    if ! list=$(local_users); then
        echo "  ${DIM}Список пользователей прочитать не удалось.${RST}"; return 0
    fi
    while IFS=: read -r name _ _ s; do
        [[ -n $name ]] || continue
        out+="${out:+, }$name"
        case $s in 1) out+=" (sudo)" ;; '?') out+=" (sudo?)" ;; esac
    done <<<"$list"
    echo "  ${DIM}Уже есть: ${out:-нет}${RST}"
}

ssh_any_key() {
    local n
    while IFS=: read -r _ _ n; do
        [[ $n =~ ^[0-9]+$ ]] && (( n > 0 )) && return 0
    done < <(ssh_key_files)
    return 1
}

ssh_show() {
    local port root_login pass_auth
    port=$(ssh_ports_display)
    root_login=$(sshd -T 2>/dev/null | awk '/^permitrootlogin /{print $2}')
    pass_auth=$(sshd -T 2>/dev/null | awk '/^passwordauthentication /{print $2}')
    echo "${BLD}${CYN}── SSH ────────────────────────────────────────────────${RST}"
    echo "  Порты: ${BLD}${port}${RST}$(ssh_socket_enabled && echo "   ${DIM}(socket-активация: порт задаёт ssh.socket)${RST}")"
    echo "  PermitRootLogin: ${root_login:-?}"
    if [[ $pass_auth == yes ]]; then
        echo "  Вход по паролю: ${YLW}разрешён${RST}"
    else
        echo "  Вход по паролю: ${GRN}запрещён${RST}"
    fi
    echo "  Ключи:"
    local u f n
    while IFS=: read -r u f n; do
        if (( n > 0 )); then
            printf '    %-14s %s — %s\n' "$u" "$f" "${GRN}${n} шт.${RST}"
        else
            printf '    %-14s %s — %s\n' "$u" "$f" "${DIM}нет${RST}"
        fi
    done < <(ssh_key_files)
    echo
}

ssh_add_key() {
    local u home f key
    ask "Для какого пользователя добавить ключ" "$TARGET_USER"; u=$REPLY_VAL
    id "$u" &>/dev/null || { err "Пользователь $u не найден."; return 1; }
    home=$(getent passwd "$u" | cut -d: -f6)
    [[ -d $home ]] || { err "Домашний каталог $home не существует."; return 1; }
    echo
    echo "${DIM}Ключ создаётся на своей машине, не на сервере. В PowerShell:"
    echo
    echo "    ${RST}${CYN}ssh-keygen -t ed25519${RST}${DIM}"
    echo
    echo "Публичный ключ ляжет в ${RST}${BLD}C:\\Users\\<твоё_имя>\\.ssh\\id_ed25519.pub${RST}${DIM} —"
    echo "открой его блокнотом и скопируй строку оттуда сюда."
    echo "Файл без .pub — приватный, его не трогай."
    echo
    echo "PuTTY и WinSCP просят формат .ppk, WinSCP сам предложит преобразовать.${RST}"
    echo
    echo "Вставь публичный ключ одной строкой (ssh-ed25519 AAAA... / ssh-rsa AAAA...):"
    printf '> '
    IFS= read -r key <"$TTY_IN" || key=''
    [[ -z $key ]] && { info "Отменено."; return 0; }
    if ! [[ $key =~ ^(ssh-(rsa|ed25519|dss)|ecdsa-sha2-[a-z0-9-]+|sk-(ssh|ecdsa)[a-z0-9@.-]*)[[:space:]]+[A-Za-z0-9+/=]+ ]]; then
        err "Это не похоже на публичный ключ. Ключ должен начинаться с ssh-ed25519 / ssh-rsa / ecdsa-sha2-..."
        return 1
    fi
    f="$home/.ssh/authorized_keys"
    mkdir -p "$home/.ssh"
    if [[ -f $f ]] && grep -qF "$(awk '{print $2}' <<<"$key")" "$f" 2>/dev/null; then
        ok "Такой ключ у $u уже есть."
        return 0
    fi
    printf '%s\n' "$key" >>"$f"
    chmod 700 "$home/.ssh"; chmod 600 "$f"
    chown -R "$u:$(id -gn "$u")" "$home/.ssh"
    ok "Ключ добавлен в $f."
    warn "Проверь вход по ключу из ДРУГОГО окна, прежде чем отключать пароли."
}

ssh_del_key() {
    local u home f line i num n
    ask "У какого пользователя удалить ключ" "$TARGET_USER"; u=$REPLY_VAL
    id "$u" &>/dev/null || { err "Пользователь $u не найден."; return 1; }
    home=$(getent passwd "$u" | cut -d: -f6)
    f="$home/.ssh/authorized_keys"
    [[ -f $f ]] || { warn "У пользователя $u нет файла $f."; return 0; }

    local -a keys=()
    while IFS= read -r line; do
        [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
        keys+=("$line")
    done <"$f"
    n=${#keys[@]}
    (( n )) || { warn "В $f нет ни одного ключа."; return 0; }

    echo
    echo "${BLD}Ключи пользователя $u:${RST}"
    i=1
    for line in "${keys[@]}"; do
        printf "  %2d) %s\n" "$i" \
            "$(printf '%s\n' "$line" | ssh-keygen -lf /dev/stdin 2>/dev/null || echo "${line:0:64}…")"
        i=$((i+1))
    done
    echo
    ask "Номер ключа для удаления (Enter — отмена)"; num=$REPLY_VAL
    [[ -z $num ]] && return 0
    if ! num=$(parse_uint "$num" 1 "$n"); then
        err "Неверный номер: получено «${REPLY_VAL}»"; return 1
    fi

    # Последний ключ при запрещённых паролях — это дорога в один конец.
    if (( n == 1 )); then
        local pass; pass=$(sshd -T 2>/dev/null | awk '/^passwordauthentication /{print $2}')
        if [[ $pass != yes ]]; then
            confirm_danger "Это единственный ключ $u, а вход по паролю запрещён. Удалив его, ты закроешь себе доступ к серверу." || return 0
        fi
    fi
    confirm_danger "Ключ #$num будет удалён из $f." || return 0

    backup_file "$f" >/dev/null
    local tmp; tmp=$(mktemp)
    i=1
    while IFS= read -r line; do
        if [[ $line =~ ^[[:space:]]*(#|$) ]]; then printf '%s\n' "$line" >>"$tmp"; continue; fi
        (( i != num )) && printf '%s\n' "$line" >>"$tmp"
        i=$((i+1))
    done <"$f"
    cat "$tmp" >"$f"; rm -f "$tmp"
    chmod 600 "$f"; chown "$u:$(id -gn "$u")" "$f" 2>/dev/null || true
    ok "Ключ удалён. Резервная копия файла — в $BACKUP_DIR."
}

ssh_disable_passwords() {
    if ! ssh_any_key; then
        err "Ни у одного пользователя нет authorized_keys."
        err "Сначала добавь ключ (пункт 1) — иначе после отключения паролей ты не войдёшь."
        return 1
    fi
    ssh_show
    confirm_danger "Вход по паролю будет отключён. Если у тебя нет рабочего ключа, доступ к серверу пропадёт. Проверь вход по ключу в другом окне ПРЯМО СЕЙЧАС." || return 0
    sshd_set PasswordAuthentication no || return 1
    sshd_set KbdInteractiveAuthentication no || return 1
    sshd_set ChallengeResponseAuthentication no || return 1
    sshd_apply || return 1

    # Проверяем по факту: другой файл в sshd_config.d может перебить наш,
    # и рапортовать об успехе, не убедившись, нельзя.
    local now
    now=$(sshd -T 2>/dev/null | awk '/^passwordauthentication /{print $2}')
    if [[ $now == no ]]; then
        ok "Вход по паролю отключён (проверено через sshd -T)."
    else
        err "sshd по-прежнему сообщает passwordauthentication=$now."
        err "Кто-то из файлов /etc/ssh/sshd_config.d/ объявляет параметр раньше нашего:"
        grep -riE '^[[:space:]]*PasswordAuthentication' /etc/ssh/sshd_config.d/ /etc/ssh/sshd_config 2>/dev/null | sed 's/^/  /'
        return 1
    fi
}

ssh_root_login() {
    echo "  ${DIM}prohibit-password — root может зайти только по ключу (рекомендуется)"
    echo "  no                — root не может зайти вообще"
    echo "  yes               — root может зайти по паролю${RST}"
    local v
    ask "PermitRootLogin [prohibit-password/no/yes]" "prohibit-password"; v=$REPLY_VAL
    case $v in
        prohibit-password|no|yes) ;;
        *) err "Допустимо: prohibit-password, no, yes."; return 1 ;;
    esac
    if [[ $v == no ]] && [[ $TARGET_USER == root ]]; then
        confirm_danger "Ты сейчас работаешь как root, а PermitRootLogin=no закроет вход root по SSH." || return 0
    fi
    sshd_set PermitRootLogin "$v" || return 1
    sshd_apply || return 1
    ok "PermitRootLogin = $v"
}

ssh_password_apply() (
    # passwd сам управляет скрытым вводом. Ни пароль, ни его повтор не должны
    # проходить через ask, переменные Bash, конвейер tee или лог run().
    [[ -t 0 ]] || { err "Для смены пароля нужен интерактивный терминал."; return 1; }
    passwd -- "$1"
) <"$TTY_IN"

ssh_change_password() {
    local u account status state rc
    users_brief
    ask "Пользователь, чей пароль изменить" "$TARGET_USER"; u=$REPLY_VAL
    [[ $u =~ ^[a-zA-Z_][a-zA-Z0-9_.-]*\$?$ ]] || { err "Некорректное имя пользователя."; return 1; }
    account=$(getent -s files passwd "$u") || { err "Локальный пользователь $u не найден."; return 1; }
    [[ ${account%%:*} == "$u" ]] || { err "Не удалось подтвердить пользователя $u."; return 1; }
    status=$(passwd -S -- "$u" 2>/dev/null) || { err "Не удалось прочитать состояние пароля $u."; return 1; }
    read -r _ state _ <<<"$status"
    echo "Будет изменён пароль учётной записи Ubuntu: ${BLD}${u}${RST}."
    echo "Он используется для входа по паролю, консоли и sudo, если sudo требует пароль."
    case $state in
        L) warn "Пароль сейчас заблокирован. Установка нового пароля может разрешить вход по паролю в эту учётную запись." ;;
        NP) warn "Сейчас у пользователя нет пароля." ;;
        P) ;;
        *) err "Состояние пароля неизвестно; смена отменена."; return 1 ;;
    esac
    echo "Запрет входа по паролю в SSH и ограничения root сохраняются."
    echo "Новый пароль вводится скрыто, дважды."
    echo "Для отмены: Ctrl+U (очистить строку), затем Ctrl+D (завершить ввод)."
    ask_yn "Изменить пароль пользователя $u?" || return 0
    log "CMD: passwd -- $u (interactive; input not logged)"
    if ssh_password_apply "$u"; then
        ok "Пароль пользователя $u изменён. Доступ по SSH проверь в новой вкладке."
    else
        rc=$?
        err "passwd завершился с кодом $rc; смена пароля не подтверждена."
        return "$rc"
    fi
}

ssh_add_user() {
    local u account rc groups
    users_brief
    ask "Имя нового пользователя (Enter — отмена)"; u=$REPLY_VAL
    [[ -n $u ]] || return 0
    [[ $u =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || {
        err "Имя: до 32 символов, строчные латинские буквы, цифры, _ и -; первый символ — буква или _."; return 1; }
    # Проверяем и NSS, и будущую домашнюю папку: чужой профиль не присваиваем.
    getent passwd "$u" >/dev/null; rc=$?
    if (( rc == 0 )); then err "Пользователь $u уже существует. Пароль меняется в 3 → 2 → 6."; return 1
    elif (( rc != 2 )); then err "Не удалось проверить существующих пользователей."; return 1; fi
    getent group "$u" >/dev/null; rc=$?
    if (( rc == 0 )); then err "Группа $u уже существует; выбери другое имя."; return 1
    elif (( rc != 2 )); then err "Не удалось проверить существующие группы."; return 1; fi
    [[ ! -e /home/$u && ! -L /home/$u ]] || { err "/home/$u уже существует; выбери другое имя."; return 1; }
    command -v useradd &>/dev/null || { err "Команда useradd не найдена."; return 1; }
    terminal_is_interactive || { err "Для установки пароля нужен интерактивный терминал."; return 1; }
    echo "Будет создан локальный пользователь $u, его группа и /home/$u, оболочка — Bash."
    echo "Пароль задашь скрыто, дважды. О правах администратора спрошу отдельно."
    ask_yn "Создать пользователя $u?" || return 0
    # До passwd новая учётная запись имеет заблокированный пароль. При сбое
    # не удаляем профиль автоматически: состояние и способ продолжения показываем.
    if ! run_quiet useradd --create-home --user-group --home-dir "/home/$u" --shell /bin/bash -- "$u"; then
        err "Создание $u не завершено. Проверь getent passwd $u и /home/$u перед повтором."; return 1
    fi
    account=$(getent -s files passwd "$u") || { err "Не удалось подтвердить создание $u."; return 1; }
    [[ ${account%%:*} == "$u" && $account == *":/home/$u:/bin/bash" ]] || {
        err "Параметры созданного пользователя отличаются от запрошенных."; return 1; }
    ok "Пользователь $u создан. Теперь установи пароль."
    log "CMD: passwd -- $u (interactive; input not logged)"
    if ssh_password_apply "$u"; then
        ok "Пароль пользователя $u установлен."
    else
        rc=$?
        err "Пользователь $u создан, но установка пароля не подтверждена. Продолжить можно в 3 → 2 → 6."
        return "$rc"
    fi
    echo "Группа sudo позволяет выполнять административные команды с паролем пользователя."
    if ask_yn "Дать пользователю $u права администратора (sudo)?"; then
        if ! command -v sudo &>/dev/null || ! getent group sudo >/dev/null; then
            err "Пользователь создан, но sudo или группа sudo отсутствует."; return 1
        fi
        run_quiet usermod -aG sudo -- "$u" || { err "Пользователь создан, но добавление в sudo не удалось."; return 1; }
        groups=$(id -nG -- "$u") || { err "Не удалось проверить группы $u."; return 1; }
        [[ " $groups " == *" sudo "* ]] || { err "Членство $u в группе sudo не подтверждено."; return 1; }
        ok "$u добавлен в группу sudo; собственные правила sudoers здесь не проверяются."
    fi
    echo "Для входа открой новую вкладку: ssh -p $(ssh_port) $u@$(primary_ip)"
    echo "Если SSH принимает только ключи, добавь ключ для $u через 3 → 2 → 1."
    echo "Создание пользователя не меняет ограничения входа SSH."
}

ssh_delete_user() {
    local u account name uid gid home shell rc list s mark num i=0
    local -a names=()
    list=$(local_users) || { err "Не удалось прочитать список локальных пользователей."; return 1; }
    echo
    echo "${BLD}Можно удалить:${RST}"
    # Выбор по номеру: опечатка в имени на удалении обходится дороже всего.
    # root, системные учётки и запустивший скрипт в список не попадают.
    while IFS=: read -r name uid home s; do
        [[ -n $name && $name != root && $name != "$TARGET_USER" && $name != "${SUDO_USER:-}" ]] || continue
        (( 10#$uid >= 1000 )) || continue
        names+=("$name"); i=$((i+1))
        mark=""
        case $s in 1) mark+="  sudo" ;; '?') mark+="  sudo?" ;; esac
        pgrep -u "$uid" >/dev/null 2>&1 && mark+="  ${YLW}работают процессы${RST}"
        printf '  %2d) %-16s UID %-6s %-20s%s\n' "$i" "$name" "$uid" "${home:-—}" "$mark"
    done <<<"$list"
    if (( ! i )); then
        info "Удалять некого: кроме root, системных учёток и тебя пользователей нет."; return 0
    fi
    echo
    ask "Номер пользователя для удаления (Enter — отмена)"; num=$REPLY_VAL
    [[ -n $num ]] || return 0
    num=$(parse_uint "$num" 1 "$i") || { err "Неверный номер: получено «${REPLY_VAL}»"; return 1; }
    u=${names[num-1]}
    [[ $u =~ ^[a-zA-Z_][a-zA-Z0-9_.-]*\$?$ ]] || { err "Некорректное имя пользователя."; return 1; }
    account=$(getent -s files passwd "$u") || { err "Локальный пользователь $u не найден или список недоступен."; return 1; }
    IFS=: read -r name _ uid gid _ home shell <<<"$account"
    [[ $name == "$u" && $uid =~ ^[0-9]+$ ]] || { err "Не удалось проверить учётную запись."; return 1; }
    if [[ $u == root || $u == "$TARGET_USER" || $u == "${SUDO_USER:-}" ]] || (( 10#$uid < 1000 || 10#$uid == 65534 )); then
        err "root, системные учётки и пользователя, запустившего скрипт, удалять нельзя."; return 1
    fi
    pgrep -u "$uid" >/dev/null 2>&1; rc=$?
    if (( rc == 0 )); then
        err "У $u есть работающие процессы или сессии. Заверши их отдельно и повтори удаление."; return 1
    elif (( rc != 1 )); then err "Не удалось проверить процессы $u; удаление отменено."; return 1; fi
    echo "Будет удалена локальная учётная запись: ${BLD}$u${RST} (UID $uid)."
    echo "Домашний каталог ${home:-не указан}, почта и остальные файлы сохранятся."
    confirm_danger "Удалить пользователя $u? Вход под этим именем станет недоступен." || return 0
    # Не используем --force и --remove: не убиваем сессии и не удаляем данные.
    run_quiet userdel -- "$u" || { err "Удаление $u не подтверждено; проверь состояние учётной записи."; return 1; }
    getent -s files passwd "$u" >/dev/null; rc=$?
    (( rc == 2 )) || { err "Не удалось подтвердить отсутствие пользователя $u."; return 1; }
    ok "Учётная запись $u удалена. Файлы сохранены."
}

ssh_listener_present() {
    local out
    out=$(ss -H -ltnp "sport = :$1" 2>/dev/null) || return 1
    grep -Eq '"(sshd|systemd)"' <<<"$out"
}

ssh_write_ports() {
    local f=$1 tmp p; shift
    tmp=$(mktemp) || return 1
    for p in "$@"; do printf 'Port %s\n' "$p" >>"$tmp"; done
    # Port складываются, а не перекрывают друг друга. Старые объявления
    # в выбранном файле убираем; чужие Include проверим через sshd -T.
    if [[ -f $f ]]; then
        awk 'tolower($1) != "port" { print }' "$f" >>"$tmp" || { rm -f "$tmp"; return 1; }
    fi
    if ! file_write "$f" 0600 <"$tmp"; then rm -f "$tmp"; return 1; fi
    rm -f "$tmp"
}

ssh_write_socket_ports() {
    local f=$1 hosts=$2 tmp host p listen; shift 2
    tmp=$(mktemp) || return 1
    printf 'ListenStream=\n' >"$tmp"
    while IFS= read -r host; do
        for p in "$@"; do printf 'ListenStream=%s:%s\n' "$host" "$p" >>"$tmp"; done
    done <<<"$hosts"
    listen=$(cat "$tmp")
    if [[ -f $f ]]; then
        # Повтор меняет слушатели в существующей секции, а не добавляет
        # ещё один пустой [Socket] и очередную ненужную резервную копию.
        awk -v listen="$listen" '
            /^\[/ {
                socket=($0 == "[Socket]"); print
                if (socket && !written) { print listen; written=1 }
                next
            }
            !(socket && /^[[:space:]]*ListenStream[[:space:]]*=/) { print }
            END { if (!written) print "\n[Socket]\n" listen }
        ' "$f" >"$tmp" || { rm -f "$tmp"; return 1; }
    else
        printf '[Socket]\n%s\n' "$listen" >"$tmp"
    fi
    if ! file_write "$f" <"$tmp"; then rm -f "$tmp"; return 1; fi
    rm -f "$tmp"
}

ssh_ports_apply() {
    local socket=$1 config actual expected; shift
    # После неудачного рестарта systemd удаляет RuntimeDirectory. Без него
    # sshd -t отвергает даже исправный конфиг и блокирует восстановление.
    if [[ ! -d /run/sshd ]]; then
        run_quiet install -d -m 0755 -o root -g root /run/sshd || return 1
    fi
    if ! config=$(sshd -t 2>&1); then
        err "Проверка конфигурации SSH не прошла — службы не перезапускаю."
        printf '%s\n' "$config" | sed 's/^/  /'
        log "sshd -t: $config"
        return 1
    fi
    config=$(sshd -T 2>/dev/null) || return 1
    actual=$(awk '$1 == "port" { print $2 }' <<<"$config" | sort -nu)
    expected=$(printf '%s\n' "$@" | sort -nu)
    [[ $actual == "$expected" ]] || {
        err "Набор портов SSH отличается от запрошенного: проверь Port в других Include."; return 1; }
    if (( socket )); then
        run_quiet systemctl daemon-reload || return 1
        # Несколько двухэтапных переходов подряд достигают StartLimitBurst.
        # Сбрасываем счётчик перед осознанным рестартом этих двух юнитов.
        run_quiet systemctl reset-failed ssh.socket ssh.service || return 1
        # Оба юнита одной транзакцией: старый sshd должен отпустить дескриптор
        # сокета до его пересоздания. KillMode=process проверяется до записи.
        run_quiet systemctl restart ssh.socket ssh.service || return 1
    else
        run_quiet systemctl reload ssh.service || return 1
    fi
    local p attempt
    for p in "$@"; do
        for attempt in 1 2 3 4 5; do
            ssh_listener_present "$p" && break
            sleep 1
        done
        ssh_listener_present "$p" || { err "SSH не слушает порт $p."; return 1; }
    done
}

ssh_restore_ports() {
    local dir=$1 socket=$2 old=$3 f i=0 rc=0
    while IFS= read -r f; do
        i=$((i+1))
        if [[ -f $dir/$i ]]; then cp -a "$dir/$i" "$f" || rc=1
        else rm -f "$f" || rc=1; fi
        if [[ -f $dir/$i.owned ]]; then file_manifest_add "$f" || rc=1
        else file_manifest_del "$f" || rc=1; fi
    done <"$dir/paths"
    (( rc == 0 )) && ssh_ports_apply "$socket" "$old" || {
        err "Автоматический откат не завершён. Исходные файлы: $dir. Не закрывай текущую сессию."; return 1; }
    ok "Исходные настройки восстановлены, SSH слушает прежний порт $old."
    ssh_transition_cleanup "$dir" || warn "Временные копии оставлены в $dir."
    return 0
}

ssh_transition_cleanup() {
    local dir=$1 f
    [[ ${dir%/*} == "$BACKUP_DIR" && ${dir##*/} == ssh-change.* && -d $dir && ! -L $dir ]] || return 1
    # Удаляем только файлы завершённого перехода этого запуска. Старые каталоги
    # могли остаться после аварии: без результата проверки их трогать нельзя.
    for f in "$dir"/* "$dir"/.[!.]* "$dir"/..?*; do
        [[ -e $f || -L $f ]] || continue
        case ${f##*/} in 1|2|1.owned|2.owned|paths) [[ -f $f && ! -L $f ]] || return 1 ;; *) return 1 ;; esac
    done
    rm -f -- "$dir/1" "$dir/2" "$dir/1.owned" "$dir/2.owned" "$dir/paths" || return 1
    rmdir -- "$dir"
}

ssh_change_port() {
    # Второй запуск не должен сохранить промежуточный конфиг как исходный.
    ( flock -n 9 || { err "Смена порта уже выполняется в другом окне."; return 1; }
      ssh_change_port_inner
    ) 9>/run/ubuntu-sh-ssh.lock
}

ssh_change_port_inner() {
    local old new
    old=$(ssh_port)
    echo "Текущий порт SSH: ${BLD}${old}${RST}"
    ask "Новый порт"; new=$REPLY_VAL
    if ! [[ $new =~ ^[0-9]{1,5}$ ]] || (( 10#$new < 1 || 10#$new > 65535 )); then
        err "Некорректный порт: получено «${new}»"; return 1
    fi
    new=$(( 10#$new ))   # убираем ведущие нули: 022 -> 22
    [[ $new == "$old" ]] && { info "Порт не меняется."; return 0; }

    local config ports busy socket=0 hosts="" raw endpoint f sf dir i=0
    config=$(sshd -T 2>/dev/null) || { err "Не удалось прочитать конфигурацию SSH."; return 1; }
    ports=$(awk '$1 == "port" { print $2 }' <<<"$config" | sort -nu)
    [[ $ports == "$old" ]] || { err "У SSH несколько портов или данные расходятся. Сначала проверь текущую конфигурацию."; return 1; }
    ssh_listener_present "$old" || { err "Не подтверждён слушатель SSH на $old."; return 1; }
    busy=$(ss -H -ltn "sport = :$new" 2>/dev/null) || return 1
    [[ -z $busy ]] || { err "Порт $new уже занят."; return 1; }
    if ssh_socket_enabled; then
        socket=1
        [[ $(systemctl show ssh.service -p KillMode --value) == process ]] || {
            err "Нестандартный KillMode SSH: автоматический перезапуск может оборвать сессии."; return 1; }
        raw=$(systemctl show ssh.socket -p Listen --value) || return 1
        while IFS= read -r endpoint; do
            endpoint=$(awk '{$1=$1; print}' <<<"$endpoint")
            [[ -z $endpoint ]] && continue
            [[ $endpoint == *":$old" ]] || { err "Нестандартный слушатель ssh.socket: $endpoint."; return 1; }
            hosts+="${endpoint%:*}"$'\n'
        done < <(sed 's/ (Stream)/\n/g' <<<"$raw")
        hosts=$(printf '%s' "$hosts" | sed '/^$/d' | sort -u)
        [[ -n $hosts ]] || { err "Не удалось определить адреса ssh.socket."; return 1; }
    fi
    # Разрешение добавляется даже на выключенном UFW, чтобы пережить выход
    # из скрипта. Ошибка firewall останавливает смену до записи SSH.
    if command -v ufw &>/dev/null; then
        ufw_allow "$new" tcp "" limit || { err "Новый порт не разрешён; SSH не меняю."; return 1; }
    fi
    f=$(sshd_target_file) || return 1
    sf=/etc/systemd/system/ssh.socket.d/override.conf
    mkdir -p "$BACKUP_DIR" || return 1
    dir=$(mktemp -d "$BACKUP_DIR/ssh-change.XXXXXX") || return 1
    chmod 700 "$dir"
    printf '%s\n' "$f" >"$dir/paths"
    (( socket )) && printf '%s\n' "$sf" >>"$dir/paths"
    while IFS= read -r endpoint; do
        i=$((i+1))
        [[ ! -L $endpoint && ( ! -e $endpoint || -f $endpoint ) ]] || return 1
        if [[ -f $endpoint ]]; then cp -a "$endpoint" "$dir/$i" || return 1; fi
        file_owned "$endpoint" && touch "$dir/$i.owned"
    done <"$dir/paths"
    if ! ssh_write_ports "$f" "$old" "$new" ||
       { (( socket )) && { ! mkdir -p "${sf%/*}" || ! ssh_write_socket_ports "$sf" "$hosts" "$old" "$new"; }; } ||
       ! ssh_ports_apply "$socket" "$old" "$new"; then
        ssh_restore_ports "$dir" "$socket" "$old"; return 1
    fi
    ok "SSH слушает оба порта: $old и $new."
    warn "Открой ДРУГОЕ окно: ssh -p $new ${TARGET_USER}@$(primary_ip)"
    if ! ask_yn "Новое подключение на порт $new работает?"; then
        ssh_restore_ports "$dir" "$socket" "$old" || return 1
        warn "Правило UFW для $new оставлено; при необходимости удали его в 3 → 1 → 2."
        return 0
    fi
    if ! ssh_write_ports "$f" "$new" ||
       { (( socket )) && ! ssh_write_socket_ports "$sf" "$hosts" "$new"; } ||
       ! ssh_ports_apply "$socket" "$new"; then
        ssh_restore_ports "$dir" "$socket" "$old"; return 1
    fi
    if ssh_listener_present "$old"; then
        warn "Старый порт $old ещё слушает SSH; правило firewall оставлено. Проверь настройки."
        return 1
    fi
    ok "SSH слушает новый порт $new; старый слушатель снят."
    ssh_transition_cleanup "$dir" || warn "Временные копии оставлены в $dir."
    if command -v ufw &>/dev/null && ask_yn "Удалить правило старого порта $old из UFW?"; then
        ufw_delete_port "$old" tcp || warn "Правило старого порта не удалено."
    fi
    f2b_set_ssh_port "$new"
}

mod_ssh() {
    command -v sshd &>/dev/null || { err "sshd не установлен."; return 1; }
    while true; do
        crumbs "SSH"
        ssh_show
        echo "${BLD}Действия:${RST}"
        echo "  1) Вставить публичный ключ"
        echo "  2) Удалить публичный ключ"
        if ssh_any_key; then
            echo "  3) Отключить вход по паролю"
        else
            echo "  ${DIM}3) Отключить вход по паролю — недоступно: нет ни одного ключа${RST}"
        fi
        echo "  4) Настроить PermitRootLogin"
        echo "  5) Сменить порт SSH"
        echo "  6) Изменить пароль пользователя"
        echo "  7) Создать пользователя"
        echo "  d) Удалить пользователя (файлы сохраняются)"
        echo "  0) Готово, дальше"
        local c
        ask "Выбор"; c=$REPLY_VAL
        case $c in
            1) ssh_add_key; pause ;;
            2) ssh_del_key; pause ;;
            3) ssh_disable_passwords; pause ;;
            4) ssh_root_login; pause ;;
            5) ssh_change_port; pause ;;
            6) ssh_change_password; pause ;;
            7) ssh_add_user; pause ;;
            d|D) ssh_delete_user; pause ;;
            0|q|Q|"") return 0 ;;
            *) err "Неверный выбор." ;;
        esac
    done
}

# ════════════════════════════════════════════════════════════════════════════
#  Firewall
# ════════════════════════════════════════════════════════════════════════════

mod_firewall() {
    ufw_ensure || return 1
    local sshp ports
    ports=$(ssh_ports) || { err "Не удалось определить порты SSH. Firewall не меняю."; return 1; }

    info "Политики по умолчанию: входящий — запретить, исходящий — разрешить."
    run_quiet ufw default deny incoming || { err "Не удалось задать политику для входящих."; return 1; }
    run_quiet ufw default allow outgoing || { err "Не удалось задать политику для исходящих."; return 1; }

    echo
    # На выключенном firewall "ufw status" правил не показывает, поэтому
    # там спрашиваем "ufw show added" — он отвечает независимо от статуса.
    ufw_load_map
    local cur
    for sshp in $ports; do
        cur=$(ufw_lookup "$sshp" tcp)
        [[ -z $cur ]] && ufw_rule_exists "$sshp" && cur="уже добавлено"
        if [[ $cur == ALLOW || $cur == LIMIT || $cur == 'уже добавлено' ]]; then
            info "Для SSH $sshp есть разрешение. Проверь его источник и порядок в 3 → 1."
        elif [[ -n $cur ]]; then
            err "Для SSH $sshp найдено правило $cur. Сначала проверь его в 3 → 1."; return 1
        else
            echo "Порт SSH: ${BLD}${sshp}${RST}"
            if ask_yn "Использовать 'limit' вместо 'allow' (встроенная защита от перебора)?"; then
                ufw_allow "$sshp" tcp "" limit || return 1
            else
                ufw_allow "$sshp" tcp || return 1
            fi
        fi
    done

    echo
    echo "Какие порты открыть, кроме SSH? По одному, Enter — закончить."
    echo "${DIM}Для веб-сервера это обычно 80 и 443, но никаких портов по умолчанию"
    echo "скрипт не открывает — только то, что назовёшь.${RST}"
    local port proto p mode
    docker_load_ports || warn "Не удалось прочитать публикации Docker. Проверь их отдельно в 3 → 1."
    while true; do
        ask "Порт (или диапазон, напр. 8000:8100)"; port=$REPLY_VAL
        [[ -z $port ]] && break
        if ! valid_port "$port"; then err "Некорректный порт."; continue; fi
        port=$(canonical_port "$port") || return 1
        ask "Протокол [tcp/udp/both]" "tcp"; proto=$REPLY_VAL
        for p in $( [[ $proto == both ]] && echo "tcp udp" || echo "$proto" ); do
            if [[ $p != tcp && $p != udp ]]; then err "Неверный протокол."; continue; fi
            mode=allow
            docker_port_selected "$port" "$p" && mode=docker
            ufw_allow "$port" "$p" "" "$mode" || return 1
            ok "Разрешение $port/$p сохранено."
        done
    done

    if ufw_active; then
        run_quiet ufw reload || return 1
    else
        run_quiet ufw --force enable || return 1
    fi

    # Порты, которые запросили модули, отработавшие до включения firewall
    # (Portainer, смена порта SSH). Открываем только теперь — раньше было некуда.
    ufw_active || { err "Активное состояние UFW не подтверждено."; return 1; }
    ufw_flush_pending || return 1

    ufw_load_map
    echo
    ufw status verbose 2>/dev/null | sed 's/^/  /'
}

# ════════════════════════════════════════════════════════════════════════════
#  Обслуживание системы
# ════════════════════════════════════════════════════════════════════════════

maint_clean() {
    title "Очистка"
    info "apt autoremove + autoclean..."
    run apt_get -y --purge autoremove || true
    run apt_get -y autoclean || true
    echo
    echo "Журнал занимает: ${BLD}$(journal_usage)${RST}"
    if ask_yn "Сжать системный журнал (оставить логи за последние 14 дней)?"; then
        run journalctl --vacuum-time=14d || true
        ok "Теперь журнал занимает: $(journal_usage)"
    fi
    echo
    if command -v docker &>/dev/null && docker info &>/dev/null; then
        docker system df 2>/dev/null | sed 's/^/  /'
        echo
        echo "${DIM}prune удаляет остановленные контейнеры, неиспользуемые сети,"
        echo "висячие образы и кэш сборки. Тома по умолчанию не трогаются.${RST}"
        if confirm_danger "Будет выполнен docker system prune -f. Остановленные контейнеры и неиспользуемые образы удалятся безвозвратно."; then
            run docker system prune -f || true
        fi
    fi
    echo
    df -h / | sed 's/^/  /'
}

maint_services() {
    title "Состояние служб"
    local u en
    for u in ssh.service sshd.service ssh.socket ufw.service fail2ban.service \
             docker.service qemu-guest-agent.service unattended-upgrades.service \
             systemd-timesyncd.service chrony.service; do
        systemctl cat "$u" &>/dev/null || continue
        # is-enabled печатает "disabled" и возвращает 1 — при "|| echo" на экран
        # попадали обе строки сразу.
        en=$(systemctl is-enabled "$u" 2>/dev/null)
        printf "  %-32s %b   %s\n" "$u" "$(svc_state "$u")" "${en:--}"
    done
    echo
    if command -v ufw &>/dev/null; then
        echo "${BLD}UFW:${RST}"
        ufw status verbose 2>/dev/null | sed 's/^/  /'
    fi
}

maint_resources() {
    title "Ресурсы"
    echo "${BLD}Диски:${RST}"
    df -hT -x tmpfs -x devtmpfs -x squashfs 2>/dev/null | sed 's/^/  /'
    echo
    echo "${BLD}Память:${RST}"
    free -h | sed 's/^/  /'
    echo
    echo "${BLD}Топ-10 процессов по памяти:${RST}"
    ps -eo pid,user,%mem,%cpu,comm --sort=-%mem 2>/dev/null | head -11 | sed 's/^/  /'
    echo
    echo "${BLD}Самые большие каталоги в /var:${RST}"
    # сам /var из списка убираем — иначе он всегда первой строкой и без пользы
    du -xh --max-depth=1 /var 2>/dev/null | grep -vE '[[:space:]]/var$' \
        | sort -rh | head -8 | sed 's/^/  /'
}

maint_logs() {
    title "Ошибки в журнале"
    echo "${BLD}Последние ошибки (priority=err) за 2 дня:${RST}"
    journalctl -p err -S -2days --no-pager 2>/dev/null | tail -40 | sed 's/^/  /' \
        || echo "  (журнал недоступен)"
    echo
    echo "${BLD}Неудачно запущенные юниты:${RST}"
    systemctl --failed --no-pager 2>/dev/null | sed 's/^/  /'
}

maint_fail2ban() {
    title "fail2ban"
    if ! command -v fail2ban-client &>/dev/null; then
        warn "fail2ban не установлен."; return 0
    fi
    if ! systemctl is-active --quiet fail2ban; then
        warn "Служба fail2ban не запущена."
        ask_yn "Запустить?" && run_quiet systemctl start fail2ban
        return 0
    fi
    # Сырой вывод fail2ban-client наполовину состоит из служебных строк вроде
    # "Journal matches" и повторов имени jail. Оставляем то, что admin читает:
    # сколько сейчас забанено, сколько было всего и кто именно сидит.
    local jail st failed_now failed_all banned_now banned_all ips any=0
    for jail in $(fail2ban-client status 2>/dev/null \
                  | awk -F: '/Jail list/{print $2}' | tr -d ' ' | tr ',' ' '); do
        any=1
        st=$(fail2ban-client status "$jail" 2>/dev/null)
        failed_now=$(awk -F'\t' '/Currently failed/{print $NF}' <<<"$st")
        failed_all=$(awk -F'\t' '/Total failed/{print $NF}'     <<<"$st")
        banned_now=$(awk -F'\t' '/Currently banned/{print $NF}' <<<"$st")
        banned_all=$(awk -F'\t' '/Total banned/{print $NF}'     <<<"$st")
        ips=$(awk -F'\t' '/Banned IP list/{print $NF}' <<<"$st")

        printf "  %-10s забанено сейчас: %s   всего банов: %s   неудачных попыток: %s\n" \
            "$jail" "${banned_now:-0}" "${banned_all:-0}" "${failed_now:-0}"
        if [[ -n ${ips// /} ]]; then
            echo "  ${DIM}в бане:${RST} $ips"
        fi
        if [[ ${failed_all:-0} != 0 && ${banned_all:-0} == 0 ]]; then
            echo "  ${DIM}попытки были, но до бана не дошло — порог $(awk -F'=' '/^maxretry/{print $2}' /etc/fail2ban/jail.local 2>/dev/null | tr -d ' ' || echo 5) за окно${RST}"
        fi
    done
    (( any )) || warn "Ни одного jail не настроено."
    echo
    if ask_yn "Разбанить IP?"; then
        local ip
        ask "IP-адрес"; ip=$REPLY_VAL
        [[ -z $ip ]] && return 0
        # unban печатает число снятых банов и выходит с кодом 0 даже при нуле —
        # сообщать об успехе, никого не разбанив, нельзя.
        local out n
        log "CMD: fail2ban-client unban $ip"
        out=$(fail2ban-client unban "$ip" 2>&1)
        printf '%s\n' "$out" >>"$LOG_FILE"
        n=$(printf '%s' "$out" | grep -oE '^[0-9]+$' | tail -1)
        if [[ ${n:-0} =~ ^[1-9] ]]; then
            ok "$ip разбанен."
        else
            warn "$ip не был забанен — разбанивать нечего."
            printf '%s\n' "$out" | sed 's/^/  /'
        fi
    fi
}


# ── Что скрипт изменил в системе ────────────────────────────────────────────
# Через полгода невозможно вспомнить, какие файлы в /etc твои, а какие
# системные. Этот раздел показывает всё, что скрипт создавал или правил,
# и умеет вернуть как было.

shared_marked() {  # есть ли в чужом файле наш кусок
    case $1 in
        /etc/ufw/after.rules|/etc/ufw/after6.rules) grep -q "BEGIN UFW AND DOCKER" "$1" 2>/dev/null ;;
        /var/lib/ubuntu-sh/docker-ports) [[ -s $1 ]] ;;
        /etc/fstab)             grep -qE '^[^#]*[[:space:]]+none[[:space:]]+swap[[:space:]]' "$1" 2>/dev/null ;;
        /etc/hosts)             grep -qE '^127\.0\.1\.1' "$1" 2>/dev/null ;;
        /etc/docker/daemon.json) grep -q "max-size" "$1" 2>/dev/null ;;
        /etc/default/zramswap)  grep -q "^PERCENT=" "$1" 2>/dev/null ;;
        *) return 1 ;;
    esac
}

backups_for() {  # копии одного файла, свежие сверху
    local src=$1 line n
    [[ -f $BACKUP_INDEX ]] || return 0
    while IFS=$'\t' read -r n line; do
        [[ $line == "$src" && -f "$BACKUP_DIR/$n" ]] && echo "$BACKUP_DIR/$n"
    # Индекс дописывается после копирования; случайная часть уникального
    # имени больше не позволяет сортировать копии по имени файла.
    done <"$BACKUP_INDEX" | tac
}

changes_show() {
    local f desc mark when
    echo "${BLD}${CYN}── Файлы настроек и их принадлежность ─────────────────${RST}"
    for f in "${OWNED_FILES[@]}"; do
        if [[ -f $f ]]; then
            when=$(date -r "$f" '+%d.%m %H:%M' 2>/dev/null)
            if file_owned "$f" && [[ ! -L $f ]]; then mark="${GRN}свой${RST}"
            else mark="${YLW}чужой${RST}"; fi
            printf "  %b %-52s %s\n" "$mark" "$f" "$when"
        else
            printf "  %b %s\n" "${DIM}нет ${RST}" "${DIM}$f${RST}"
        fi
    done
    echo "  ${DIM}Без записи в манифесте файл считается чужим, в том числе от старых запусков.${RST}"

    echo
    echo "${BLD}${CYN}── Правки в системных файлах ──────────────────────────${RST}"
    local entry
    for entry in "${SHARED_FILES[@]}"; do
        f=${entry%%|*}; desc=${entry#*|}
        if shared_marked "$f"; then mark="${GRN}есть${RST}"; else mark="${DIM}нет ${RST}"; fi
        printf "  %b %-30s %s\n" "$mark" "$f" "${DIM}${desc}${RST}"
    done

    echo
    local cnt size
    cnt=$(ls -1 "$BACKUP_DIR" 2>/dev/null | wc -l)
    size=$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1)
    echo "${BLD}${CYN}── Резервные копии ────────────────────────────────────${RST}"
    if (( cnt )); then
        echo "  $BACKUP_DIR — ${cnt} шт., ${size:-?}"
        ls -1t "$BACKUP_DIR" 2>/dev/null | head -5 | sed 's/^/    /'
        (( cnt > 5 )) && echo "    ${DIM}…и ещё $((cnt - 5))${RST}"
    else
        echo "  ${DIM}копий пока нет${RST}"
    fi
    echo
}

# Выбор файла из объединённого списка. Результат — в PICKED_FILE, как это
# сделано с REPLY_VAL: nameref (local -n) при set -u падает на переменной,
# которой ещё не присвоено значение.
PICKED_FILE=""
changes_pick_file() {
    PICKED_FILE=""
    local i=1 f entry all=()
    for f in "${OWNED_FILES[@]}"; do all+=("$f"); done
    for entry in "${SHARED_FILES[@]}"; do all+=("${entry%%|*}"); done
    echo
    for f in "${all[@]}"; do printf "  %2d) %s\n" "$i" "$f"; i=$((i+1)); done
    ask "Номер файла (Enter — отмена)"
    [[ -z $REPLY_VAL ]] && return 1
    if ! [[ $REPLY_VAL =~ ^[0-9]+$ ]] || (( REPLY_VAL < 1 || REPLY_VAL > ${#all[@]} )); then
        err "Неверный номер: получено «${REPLY_VAL}»"; return 1
    fi
    PICKED_FILE=${all[$((REPLY_VAL-1))]}
}

changes_view() {
    local f
    changes_pick_file || return 0
    f=$PICKED_FILE
    [[ -f $f ]] || { warn "Файла $f нет."; return 0; }
    echo
    echo "${BLD}$f${RST}"
    hr
    sed 's/^/  /' "$f"
    hr
}

# Подменённый или удалённый файл сам по себе ничего не меняет: службу надо
# перечитать. Таблица общая для удаления и восстановления — иначе один пункт
# доводит дело до конца, а другой оставляет систему в промежуточном виде.
apply_after_change() {
    local f=$1 name
    case $f in
        /etc/hostname)
            if [[ -s $f ]]; then
                name=$(head -1 "$f" | tr -d '[:space:]')
                run_quiet hostnamectl set-hostname "$name" && ok "Имя хоста применено: $name"
            fi ;;
        /etc/sysctl.d/*)                run_quiet sysctl --system >/dev/null; ok "sysctl перечитан." ;;
        /etc/systemd/journald.conf.d/*) run_quiet systemctl restart systemd-journald; ok "journald перезапущен." ;;
        /etc/fail2ban/jail.local)       run_quiet systemctl restart fail2ban && ok "fail2ban перезапущен." ;;
        /etc/ssh/sshd_config|/etc/ssh/sshd_config.d/*)
            run_quiet systemctl reload ssh 2>/dev/null && ok "Настройки SSH перечитаны." ;;
        /etc/systemd/system/ssh.socket.d/*)
            run_quiet systemctl daemon-reload
            warn "Порт SSH сменится после перезапуска ssh.socket." ;;
        /etc/docker/daemon.json)
            run_quiet systemctl restart docker && ok "Docker перезапущен." ;;
        /etc/ufw/after.rules|/etc/ufw/after6.rules)
            ufw_active && { run_quiet ufw reload; ok "Правила ufw перечитаны."; } ;;
        /etc/default/zramswap)
            run_quiet systemctl restart zramswap 2>/dev/null && ok "zram перезапущен." ;;
        # эти читаются на месте при каждом обращении — перезапускать нечего
        /etc/hosts|/etc/fstab|/etc/apt/apt.conf.d/*|*/.ssh/authorized_keys) ;;
        *)
            warn "Служба, которой принадлежит файл, не перезапущена — скрипт её не угадывает." ;;
    esac
    return 0   # неудачный перезапуск не должен выглядеть как провал всего пункта
}

changes_delete_owned() {
    local i=1 f candidates=()
    echo
    for f in "${OWNED_FILES[@]}"; do
        [[ -f $f && ! -L $f ]] && file_owned "$f" || continue
        candidates+=("$f")
        printf "  %2d) %s\n" "$i" "$f"
        i=$((i+1))
    done
    (( ${#candidates[@]} )) || { info "Нет файлов, создание которых подтверждено манифестом."; return 0; }
    ask "Номер файла для удаления (Enter — отмена)"
    [[ -z $REPLY_VAL ]] && return 0
    if ! [[ $REPLY_VAL =~ ^[0-9]+$ ]] || (( 10#$REPLY_VAL < 1 || 10#$REPLY_VAL > ${#candidates[@]} )); then
        err "Неверный номер: получено «${REPLY_VAL}»"; return 1
    fi
    f=${candidates[$((10#$REPLY_VAL-1))]}
    [[ -f $f && ! -L $f ]] && file_owned "$f" || { err "Принадлежность файла не подтверждена."; return 1; }

    case $f in
        /etc/ssh/sshd_config.d/*|/etc/systemd/system/ssh.socket.d/*)
            confirm_danger "Удаление $f вернёт настройки SSH к системным: порт, парольный вход и root-логин станут как до правок. Текущая сессия не разорвётся, но следующее подключение может пойти на другой порт." || return 0 ;;
        *)
            confirm_danger "Файл $f будет удалён, настройка вернётся к системной по умолчанию." || return 0 ;;
    esac

    backup_file "$f" >/dev/null || return 1
    file_manifest_del "$f" || return 1
    rm -f "$f" || return 1
    ok "Удалён: $f (копия сохранена)."
    apply_after_change "$f"
}

changes_drop_docker_block() {
    local f
    ufw_docker_fix_applied || { warn "Полный блок Docker+UFW не найден; проверь after.rules и after6.rules."; return 0; }
    confirm_danger "Блок правил будет убран: порты контейнеров снова станут доступны снаружи в обход UFW." || return 0
    for f in "$UFW_AFTER4" "$UFW_AFTER6"; do backup_file "$f" >/dev/null || return 1; done
    ufw_docker_block_remove || return 1
    docker_filter_clear || return 1
    ok "Блок убран."
    if ufw_active; then run_quiet ufw reload && ok "UFW перезагружен."; fi
}

# Восстанавливать можно только то, для чего есть копия, поэтому список
# строится из самого каталога копий, а не из перечня файлов скрипта: иначе
# половина пунктов упиралась в «копий нет», а authorized_keys, копии которого
# есть, в перечень вообще не входил.
backup_sources() {  # исходные пути, для которых есть копии
    [[ -f $BACKUP_INDEX ]] || return 0
    local n src
    while IFS=$'\t' read -r n src; do
        [[ -n $src && -f "$BACKUP_DIR/$n" ]] && echo "$src"
    done <"$BACKUP_INDEX" | sort -u
}

# Копии, сделанные до появления индекса: путь из имени восстановить нельзя,
# поэтому просто сообщаем, что они есть.
backups_unindexed() {
    [[ -d $BACKUP_DIR ]] || return 0
    local b n
    for b in "$BACKUP_DIR"/*; do
        [[ -f $b ]] || continue
        n=${b##*/}
        grep -qF "$(printf '%s\t' "$n")" "$BACKUP_INDEX" 2>/dev/null || echo "$n"
    done
}

changes_restore() {
    local f copies=() i=1 pick srcs=()
    mapfile -t srcs < <(backup_sources)
    local old=(); mapfile -t old < <(backups_unindexed)
    if (( ${#srcs[@]} == 0 )); then
        warn "Восстанавливать нечего: копий с записью о пути пока нет."
        (( ${#old[@]} )) && echo "${DIM}  В каталоге есть $(plural ${#old[@]} копия копии копий) от прежней версии" \
            && echo "${DIM}  скрипта — куда их класть, он тогда не записывал. Файлы целы:" \
            && echo "  $BACKUP_DIR${RST}"
        return 0
    fi
    echo
    echo "${BLD}Файлы, для которых есть копии:${RST}"
    for f in "${srcs[@]}"; do
        local n newest
        mapfile -t copies < <(backups_for "$f")
        n=${#copies[@]}
        newest=${copies[0]##*.}
        printf "  %2d) %-46s %s, свежая %s\n" "$i" "$f" \
            "$(plural "$n" копия копии копий)" \
            "$(date -d "${newest:0:8} ${newest:9:2}:${newest:11:2}" '+%d.%m %H:%M' 2>/dev/null || echo "$newest")"
        i=$((i+1))
    done
    ask "Номер файла (Enter — отмена)"; pick=$REPLY_VAL
    [[ -z $pick ]] && return 0
    if ! pick=$(parse_uint "$pick" 1 "${#srcs[@]}"); then
        err "Неверный номер: получено «${REPLY_VAL}»"; return 1
    fi
    f=${srcs[$((pick-1))]}
    i=1
    mapfile -t copies < <(backups_for "$f")
    (( ${#copies[@]} )) || { warn "Копий для $f нет."; return 0; }
    echo
    echo "Копии $f, свежие сверху:"
    for pick in "${copies[@]}"; do
        printf "  %2d) %s  %s\n" "$i" "${pick##*.}" "$(du -h "$pick" 2>/dev/null | cut -f1)"
        i=$((i+1))
    done
    ask "Номер копии (Enter — отмена)"; pick=$REPLY_VAL
    [[ -z $pick ]] && return 0
    if ! pick=$(parse_uint "$pick" 1 "${#copies[@]}"); then
        err "Неверный номер: получено «${REPLY_VAL}»"; return 1
    fi
    confirm_danger "Текущий $f будет заменён копией от ${copies[$((pick-1))]##*.}." || return 0
    backup_file "$f" >/dev/null || return 1  # текущее состояние тоже сохраняем
    # В старых копиях нет сведений о владельце: восстановленный файл нельзя
    # предлагать удалить целиком на основании записи от заменённой версии.
    file_manifest_del "$f" || return 1
    cp -a "${copies[$((pick-1))]}" "$f" || return 1
    ok "Восстановлен: $f"
    apply_after_change "$f"
}

maint_changes() {
    while true; do
        crumbs "Что изменил скрипт"
        changes_show
        echo "${BLD}Действия:${RST}"
        echo "  1) Показать содержимое файла"
        echo "  2) Удалить файл, созданный скриптом"
        echo "  3) Убрать блок Docker+UFW из after.rules"
        echo "  4) Восстановить файл из резервной копии"
        echo "  0) Назад"
        local c
        ask "Выбор"; c=$REPLY_VAL
        case $c in
            1) changes_view; pause ;;
            2) changes_delete_owned; pause ;;
            3) changes_drop_docker_block; pause ;;
            4) changes_restore; pause ;;
            0|q|Q|"") return 0 ;;
            *) err "Неверный выбор." ;;
        esac
    done
}

maint_reboot() {
    title "Перезагрузка"
    if reboot_required; then
        warn "Система сообщает, что перезагрузка требуется:"
        [[ -f /var/run/reboot-required.pkgs ]] && sed 's/^/    /' /var/run/reboot-required.pkgs
    else
        ok "Перезагрузка не требуется."
    fi
    echo
    echo "Аптайм: $(uptime -p 2>/dev/null || uptime)"
    echo
    confirm_danger "Сервер будет перезагружен прямо сейчас." || { info "Отменено."; return 0; }
    log "REBOOT по запросу пользователя"
    ok "Перезагружаюсь..."
    sleep 2
    systemctl reboot
}


# ════════════════════════════════════════════════════════════════════════════
#  Информация о системе
# ════════════════════════════════════════════════════════════════════════════



# ── Менеджер установленного софта ───────────────────────────────────────────
# Три категории: что поставил скрипт (по манифесту), что поставили руками
# и системное. Удалять можно из первых двух, системное — только смотреть.

# Снести это по номеру из меню — потерять машину или доступ к ней.
PKG_PROTECTED=(
    ufw openssh-server openssh-client sudo systemd systemd-sysv init
    apt dpkg bash coreutils util-linux libc6 login passwd
    ubuntu-server ubuntu-server-minimal ubuntu-minimal ubuntu-standard
    linux-generic linux-image-generic grub-pc grub-common grub2-common
    netplan.io cloud-init openssh-sftp-server
)

# Список имён выше закрывает то, что важно именно для этого скрипта. Но основа
# системы шире: dash, grep, gzip, hostname помечены Essential, и на них по
# правилам Debian никто не объявляет зависимостей — в перечень из 25 имён они
# не попадут, а снос любого убивает машину. Спрашиваем сам dpkg.
declare -A PKG_CORE=()
PKG_CORE_READY=0
pkg_core_load() {   # один вызов dpkg-query вместо одного на пакет
    (( PKG_CORE_READY )) && return 0
    local p
    while read -r p; do [[ -n $p ]] && PKG_CORE[$p]=1; done < <(
        dpkg-query -W -f='${Package} ${Essential} ${Priority}\n' 2>/dev/null \
        | awk '$2=="yes" || $3=="required" || $3=="important" {print $1}')
    PKG_CORE_READY=1
}

pkg_essential() {
    pkg_core_load
    [[ -n ${PKG_CORE[$1]:-} ]]
}

pkg_protected() {
    local p
    for p in "${PKG_PROTECTED[@]}"; do [[ $1 == "$p" ]] && return 0; done
    pkg_essential "$1" && return 0
    return 1
}

# Пакеты из манифеста, которые реально стоят в системе
soft_from_manifest() {
    [[ -f $PKG_MANIFEST ]] || return 0
    local line p
    while IFS='|' read -r p _ _; do
        [[ -n $p ]] || continue
        pkg_installed "$p" && echo "$p"
    done <"$PKG_MANIFEST" | sort -u
}

# Базовый набор системы. `apt-mark showmanual` для этого не годится: установщик
# помечает так весь свой набор, и в «поставлено вручную» попадали vim, curl и
# ещё полсотни пакетов, которых никто не ставил. Опора надёжнее — метапакеты:
# что они тянут, то принесла установка системы, а не человек.
SEED_ROOTS=(ubuntu-minimal ubuntu-standard ubuntu-server ubuntu-server-minimal
            cloud-init linux-generic snapd)
SEED_CACHE=""
soft_seed() {
    [[ -n $SEED_CACHE ]] && { printf '%s\n' "$SEED_CACHE"; return 0; }
    local r roots=()
    for r in "${SEED_ROOTS[@]}"; do pkg_installed "$r" && roots+=("$r"); done
    (( ${#roots[@]} )) || return 0
    SEED_CACHE=$(apt-cache --installed --recurse --no-suggests --no-conflicts \
        --no-breaks --no-replaces --no-enhances depends "${roots[@]}" 2>/dev/null \
        | grep -v '^[[:space:]]' | grep -v '^<' | sort -u)
    printf '%s\n' "$SEED_CACHE"
}

# Поставленное после установки системы: showmanual минус базовый набор,
# минус манифест скрипта, минус защищённое
soft_manual() {
    local p
    local -A known=()
    while read -r p; do known[$p]=1; done < <(soft_from_manifest)
    while read -r p; do known[$p]=1; done < <(soft_seed)
    while read -r p; do
        [[ -n ${known[$p]:-} ]] && continue
        pkg_protected "$p" && continue
        echo "$p"
    done < <(apt-mark showmanual 2>/dev/null | sort -u)
}

soft_count_all() { dpkg-query -f '.\n' -W 2>/dev/null | wc -l; }

# Кого apt снесёт на самом деле, если удалить пакет
purge_victims() {  # purge_victims curl → curl, libcurl4t64, ubuntu-server…
    local out
    out=$(apt_get -s purge "$1" 2>&1) || {
        log "APT purge simulation failed: $out"
        return 1
    }
    # apt purge печатает Purg, а не Remv: иначе зависимости исчезают
    # из проверки защиты, хотя реальный purge их удалит.
    printf '%s\n' "$out" | awk '/^(Remv|Purg) /{sub(/:.*/,"",$2); print $2}' | sort -u
}

# Общий обработчик удаления: показывает, что потянется следом
soft_remove_menu() {  # soft_remove_menu "заголовок" функция-источник
    local title=$1 src=$2 i=1 p num
    local -a list=()
    mapfile -t list < <($src)
    if (( ${#list[@]} == 0 )); then
        warn "Список пуст."
        return 0
    fi
    echo
    echo "${BLD}${title} (${#list[@]}):${RST}"
    for p in "${list[@]}"; do
        printf "  %2d) %-28s %s\n" "$i" "$p" \
            "${DIM}$(dpkg-query -f '${binary:Summary}' -W "$p" 2>/dev/null | cut -c1-40)${RST}"
        i=$((i+1))
    done
    echo
    ask "Номер пакета для удаления (Enter — назад)"; num=$REPLY_VAL
    [[ -z $num ]] && return 0
    if ! num=$(parse_uint "$num" 1 "${#list[@]}"); then
        err "Неверный номер: получено «${REPLY_VAL}»"; return 1
    fi
    p=${list[$((num-1))]}

    if pkg_protected "$p"; then
        err "$p из списка защищённых — удалять его отсюда нельзя."
        return 1
    fi

    # Защита по имени выбранного пакета мало что значит: curl утащил за собой
    # ubuntu-server и ubuntu-server-minimal, а подтверждение спрашивало про curl.
    # Поэтому смотрим, что apt собирается снести на самом деле.
    local -a doomed=() hit=()
    local victims
    if ! victims=$(purge_victims "$p"); then
        err "APT не смог проверить последствия удаления $p. Удаление отменено; подробности в $LOG_FILE."
        return 1
    fi
    if ! grep -Fxq -- "${p%%:*}" <<<"$victims"; then
        err "APT не подтвердил список удаления $p. Удаление отменено."
        return 1
    fi
    mapfile -t doomed <<<"$victims"
    local d
    for d in "${doomed[@]}"; do pkg_protected "$d" && hit+=("$d"); done
    if (( ${#hit[@]} )); then
        err "Удаление $p потянет за собой системные пакеты: ${hit[*]}"
        err "Без них машина теряет базовый набор или доступ по сети. Отказываю."
        info "Если это всё-таки нужно — делай вручную, apt покажет полный список."
        return 1
    fi

    echo
    info "Что произойдёт при удалении $p:"
    if (( ${#doomed[@]} > 1 )); then
        echo "  Будет удалено $(plural ${#doomed[@]} пакет пакета пакетов):"
        printf '  %s\n' "${doomed[*]}" | fold -s -w 66 | sed 's/^/  /'
    else
        echo "  Будет удалён только $p."
    fi
    echo

    # Docker тащит за собой контейнеры и тома, о них надо сказать отдельно
    if [[ $p == docker-ce ]]; then
        warn "Контейнеры, образы и тома в /var/lib/docker после удаления пакета останутся."
        warn "Если нужны и они — удаляй каталог отдельно, вручную."
    fi

    confirm_danger "Пакет $p и его настройки будут удалены (purge)." || return 0
    if run apt_get purge -y "$p"; then
        manifest_del "$p"
        ok "$p удалён."
        if ask_yn "Убрать заодно осиротевшие зависимости (autoremove)?"; then
            run apt_get -y --purge autoremove || true
        fi
    else
        err "Не удалось удалить $p."
        return 1
    fi
}

soft_install() {
    echo "Через пробел, например: ${DIM}ncdu iftop tmux${RST}"
    ask "Какие пакеты поставить (Enter — отмена)"
    [[ -z $REPLY_VAL ]] && return 0
    local pkgs=()
    read -r -a pkgs <<<"$REPLY_VAL"
    CURRENT_MODULE="вручную"
    pkg_install "${pkgs[@]}"
}

soft_search_system() {
    ask "Часть имени пакета (Enter — назад)"
    [[ -z $REPLY_VAL ]] && return 0
    echo
    dpkg-query -f '${binary:Package}\t${Version}\t${binary:Summary}\n' -W 2>/dev/null \
        | grep -i -- "$REPLY_VAL" | head -40 | sed 's/^/  /' \
        || echo "  ничего не найдено"
}

mod_software() {
    while true; do
        clear
        echo "${BLD}${BLU}╔══════════════════════════════════════════════════════════╗"
        echo "║                  Установленный софт                      ║"
        echo "╚══════════════════════════════════════════════════════════╝${RST}"
        crumbs "Установленный софт"
        echo
        local n_script n_manual n_all
        n_script=$(soft_from_manifest | wc -l)
        n_manual=$(soft_manual | wc -l)
        n_all=$(soft_count_all)
        echo "  ${BLD}1)${RST} Поставлено этим скриптом  ${BLD}${n_script}${RST}"
        echo "  ${BLD}2)${RST} После установки системы   ${BLD}${n_manual}${RST}   ${DIM}не из образа и не скриптом${RST}"
        echo "  ${BLD}3)${RST} Всё установленное         ${BLD}${n_all}${RST}   ${DIM}поиск, без удаления${RST}"
        echo "  ${BLD}4)${RST} Установить пакеты"
        echo "  ${BLD}0)${RST} Назад"
        echo
        echo "${DIM}  Системные пакеты и всё, без чего машина не работает или теряет"
        echo "  доступ по сети, из удаления исключены.${RST}"
        echo
        local c
        ask "Выбор"; c=$REPLY_VAL
        case $c in
            1) soft_remove_menu "Поставлено этим скриптом" soft_from_manifest; pause ;;
            2) soft_remove_menu "Поставлено после установки системы" soft_manual; pause ;;
            3) soft_search_system; pause ;;
            4) soft_install; pause ;;
            0|q|Q|"") return 0 ;;
            *) err "Неверный выбор."; sleep 1 ;;
        esac
    done
}

# ── Проверка безопасности ───────────────────────────────────────────────────
# Один экран перед тем, как выставлять машину наружу. Каждая строка —
# утверждение о факте с пометкой, а не совет вообще.

AUDIT_BAD=0
AUDIT_WARN=0

a_ok()   { printf "  %b %s\n" "${GRN}✔${RST}" "$1"; }
a_warn() { printf "  %b %s\n" "${YLW}!${RST}" "$1"; AUDIT_WARN=$((AUDIT_WARN+1)); }
a_bad()  { printf "  %b %s\n" "${RED}✘${RST}" "$1"; AUDIT_BAD=$((AUDIT_BAD+1)); }

audit_ssh() {
    echo "${BLD}${CYN}── Доступ по SSH ──────────────────────────────────────${RST}"
    local port ports pass root config
    ports=$(ssh_ports) || ports=""
    config=$(sshd -T 2>/dev/null) || config=""
    pass=$(awk '/^passwordauthentication /{print $2}' <<<"$config")
    root=$(awk '/^permitrootlogin /{print $2}' <<<"$config")

    if [[ -z $ports ]]; then a_warn "Порты SSH: не удалось определить."
    else
        for port in $ports; do
            [[ $port == 22 ]] && a_warn "Порт 22 — стандартный, перебор идёт постоянно." \
                              || a_ok "Порт $port — нестандартный."
        done
    fi
    case $pass in
        yes) a_bad  "Вход по паролю разрешён." ;;
        no)  a_ok   "Вход по паролю запрещён." ;;
        *)   a_warn "Вход по паролю: не удалось определить." ;;
    esac
    case $root in
        yes)               a_bad "root может зайти по паролю." ;;
        prohibit-password) a_ok  "root — только по ключу." ;;
        no)                a_ok  "root по SSH не пускается." ;;
        *)                 a_warn "PermitRootLogin: ${root:-неизвестно}." ;;
    esac

    local u f n keyed=0
    while IFS=: read -r u f n; do
        if [[ $n =~ ^[0-9]+$ ]] && (( n > 0 )); then
            a_ok "У $u ключей: $n"
            keyed=1
        fi
    done < <(ssh_key_files)
    (( keyed )) || a_warn "Ключей нет ни у кого — доступ держится только на пароле."
    echo
}

audit_exposure() {
    echo "${BLD}${CYN}── Слушатели и фильтрация на этой машине ──────────────${RST}"
    ufw_load_map
    docker_load_ports || a_warn "Docker не отвечает: список публикаций неизвестен."
    local state proto addr port proc act sockets key any=0
    state=$(ufw_state)
    case $state in
        active) a_ok "UFW активен; правила и политика показаны ниже." ;;
        inactive|missing) a_warn "UFW не фильтрует трафик. Другие firewall этим тестом не проверяются." ;;
        *) a_warn "Не удалось определить состояние UFW." ;;
    esac
    sockets=$(list_sockets) || { a_warn "Не удалось прочитать слушатели."; return 1; }
    while IFS='|' read -r proto addr port proc; do
        [[ -n $port ]] || continue
        is_localhost_addr "$addr" && continue
        any=1
        printf '  %s/%s на %s (%s) — слушает; доступ извне не проверен.\n' "$port" "$proto" "$addr" "$proc"
    done <<<"$sockets"
    if (( ${#DOCKER_PORTS[@]} )); then
        for key in $(printf '%s\n' "${!DOCKER_PORTS[@]}" | sort -V); do
            printf '  Docker %s — %s.\n' "$key" "$(docker_permission_summary "${key%/*}" "${key#*/}")"
        done
        echo "  Записи реестра не доказывают доступность извне; учитывай источник, адрес и обычные правила UFW для proxy."
        if docker_fix_live; then a_ok "Фильтр Docker загружен; разрешения по внешнему порту — в 3 → 1."
        else a_warn "Фильтрация публикаций Docker не подтверждена; проверь доступ с другой машины."; fi
    fi
    (( any )) || info "Не обнаружены слушатели вне localhost; публикации Docker проверяются отдельно."
    echo
}

audit_rules() {
    echo "${BLD}${CYN}── Правила firewall ───────────────────────────────────${RST}"
    local out
    if [[ $(ufw_state) != active ]]; then
        a_warn "Политики UFW не прочитаны: состояние $(ufw_state)."
        return 0
    fi
    out=$(ufw status verbose 2>/dev/null) || { a_warn "Не удалось прочитать правила UFW."; return 1; }
    # Не сворачиваем таблицу в «порт открыт»: направление, порядок,
    # семейство адресов и источник меняют смысл одного и того же ALLOW.
    printf '%s\n' "$out" | sed 's/^/  /'
    echo
}

audit_accounts() {
    echo "${BLD}${CYN}── Учётные записи и права ─────────────────────────────${RST}"
    local u members
    members=$(getent group docker 2>/dev/null | cut -d: -f4)
    if [[ -n $members ]]; then
        a_warn "В группе docker: ${members//,/, } — это равносильно root на этой машине."
    else
        a_ok "В группе docker никого."
    fi

    # sudo без пароля — частая забытая настройка
    if grep -rqE '^[^#]*NOPASSWD' /etc/sudoers /etc/sudoers.d/ 2>/dev/null; then
        a_warn "Есть правила sudo с NOPASSWD:"
        grep -rhE '^[^#]*NOPASSWD' /etc/sudoers /etc/sudoers.d/ 2>/dev/null | sed 's/^/      /'
    else
        a_ok "sudo без пароля не настроен."
    fi

    # пользователи с пустым паролем
    local empty
    empty=$(awk -F: '($2 == "") {print $1}' /etc/shadow 2>/dev/null | tr '\n' ' ')
    [[ -n $empty ]] && a_bad "Пустой пароль у: $empty" || a_ok "Учёток с пустым паролем нет."
    echo
}

audit_services() {
    echo "${BLD}${CYN}── Защита и обновления ────────────────────────────────${RST}"
    if systemctl is-active --quiet fail2ban 2>/dev/null; then
        if fail2ban-client status sshd &>/dev/null; then
            a_ok "fail2ban работает, jail sshd активен."
        else
            a_warn "fail2ban запущен, но jail sshd не отвечает."
        fi
    else
        a_warn "fail2ban не работает или его состояние не удалось прочитать."
    fi

    if systemctl is-enabled --quiet unattended-upgrades 2>/dev/null; then
        printf '  unattended-upgrades: служба включена; расписание и политика APT здесь не проверяются.\n'
    else
        a_warn "Включение службы unattended-upgrades не подтверждено."
    fi

    local pend apt_out
    if apt_out=$(apt_get -s -o Debug::NoLocking=1 upgrade 2>/dev/null); then
        pend=$(grep -c '^Inst .*security' <<<"$apt_out" || true)
        (( pend )) && a_warn "APT предлагает обновлений из security: $pend" \
                   || printf '  По локальным индексам APT обновления из security не предложены; свежесть индексов не проверялась.\n'
    else
        a_warn "Не удалось проверить обновления безопасности через APT."
    fi

    reboot_required && a_warn "Требуется перезагрузка — ядро или библиотеки обновлены." \
                    || a_ok "Перезагрузка не требуется."

    # IPv6 проверяем именно здесь: расхождение между sysctl.d и реальным
    # состоянием интерфейса появляется только после перезагрузки.
    if ipv6_disabled; then
        local dev value bad=() unread=()
        for dev in /sys/class/net/*; do
            [[ -e $dev ]] || continue
            dev=${dev##*/}
            case $dev in lo|docker*|br-*|veth*|virbr*|tap*|tun*|cni*|flannel*) continue ;; esac
            if value=$(sysctl -n "net.ipv6.conf.$dev.disable_ipv6" 2>/dev/null); then
                case $value in 0) bad+=("$dev") ;; 1) ;; *) unread+=("$dev") ;; esac
            else
                unread+=("$dev")
            fi
        done
        if (( ${#bad[@]} )); then
            a_warn "IPv6 отключён в sysctl, но на ${bad[*]} включён — вернул сетевой менеджер."
        elif (( ${#unread[@]} == 0 )); then
            a_ok "IPv6 отключён и на интерфейсах тоже."
        fi
        (( ${#unread[@]} == 0 )) || a_warn "Не удалось проверить IPv6 на: ${unread[*]}."
    fi
    echo
}

security_audit() {
    clear
    AUDIT_BAD=0; AUDIT_WARN=0
    echo "${BLD}${BLU}╔══════════════════════════════════════════════════════════╗"
    echo "║                 Проверка безопасности                    ║"
    echo "╚══════════════════════════════════════════════════════════╝${RST}"
    crumbs "Проверка безопасности"
    echo "${DIM}  $(hostname) · $(primary_ip) · $(date '+%F %T')${RST}"
    echo
    audit_ssh
    audit_exposure
    audit_rules
    audit_accounts
    audit_services
    # Подробности про netplan печатаем один раз, только если есть что чинить
    ipv6_disabled && ipv6_check_interfaces
    hr
    if (( AUDIT_BAD )); then
        echo "${BLD}${RED}Серьёзных проблем: $AUDIT_BAD${RST}   замечаний: $AUDIT_WARN"
        echo "Красные строки — это то, через что машину и ломают. Начни с них."
    elif (( AUDIT_WARN )); then
        echo "${BLD}${YLW}Серьёзных проблем нет, замечаний: $AUDIT_WARN${RST}"
    else
        echo "${BLD}${GRN}Замечаний нет.${RST}"
    fi
}

system_info() {
    clear
    echo "${BLD}${BLU}╔══════════════════════════════════════════════════════════╗"
    echo "║                  Информация о системе                    ║"
    echo "╚══════════════════════════════════════════════════════════╝${RST}"
    crumbs "Информация о системе"
    echo
    printf "  %s %s\n" "$(pad "Хост:" 22)" "$(hostname)"
    printf "  %s %s\n" "$(pad "ОС:" 22)" "$(os_pretty)"
    printf "  %s %s\n" "$(pad "Ядро:" 22)" "$(uname -r)"
    printf "  %s %s\n" "$(pad "Виртуализация:" 22)" "$(virt_type)"
    printf "  %s %s\n" "$(pad "Аптайм:" 22)" "$(uptime -p 2>/dev/null || true)"
    printf "  %s %s\n" "$(pad "Время:" 22)" "$(date '+%F %T %Z')  (NTP: $(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo '?'))"
    printf "  %s %s\n" "$(pad "IP-адреса:" 22)" "$(hostname -I 2>/dev/null)"
    printf "  %s %s\n" "$(pad "CPU:" 22)" "$(nproc) ядер, $(awk -F: '/model name/{print $2; exit}' /proc/cpuinfo 2>/dev/null | sed 's/^ *//')"
    printf "  %s %s\n" "$(pad "Память:" 22)" "$(free -h | awk '/^Mem:/{print $3" из "$2}')"
    printf "  %s %s\n" "$(pad "Корень:" 22)" "$(df -h / | awk 'NR==2{print $3" из "$2" ("$5")"}')"
    printf "  %s %s\n" "$(pad "Swap:" 22)" "$(free -h | awk '/^Swap:/{print ($2=="0B"?"нет":$3" из "$2)}')"
    printf "  %s %s\n" "$(pad "IPv6:" 22)" "$(ipv6_disabled && echo 'отключён' || echo 'включён')"
    printf "  %s %s\n" "$(pad "SSH:" 22)" "порты $(ssh_ports_display), пароли: $(sshd -T 2>/dev/null | awk '/^passwordauthentication /{print ($2=="yes"?"разрешены":"запрещены")}')"
    if command -v ufw &>/dev/null; then
        printf "  %s %b\n" "$(pad "UFW:" 22)" "$(ufw_active && echo "${GRN}активен${RST}" || echo "${YLW}выключен${RST}")"
    fi
    if command -v fail2ban-client &>/dev/null; then
        printf "  %s %b\n" "$(pad "fail2ban:" 22)" "$(svc_state fail2ban.service)"
    fi
    if command -v docker &>/dev/null; then
        printf "  %s %s\n" "$(pad "Docker:" 22)" "$(docker --version 2>/dev/null | sed 's/,.*//')"
        printf "  %s %s\n" "$(pad "Контейнеров запущено:" 22)" "$(docker ps -q 2>/dev/null | wc -l)"
        ufw_docker_fix_applied && printf "  %s %s\n" "$(pad "Docker+UFW:" 22)" "фикс применён"
    fi
    reboot_required && { echo; warn "Требуется перезагрузка системы."; }
    echo
    ufw_load_map
    docker_load_ports
    show_listening
    show_ufw_rules
    echo "${DIM}Лог работы скрипта: $LOG_FILE${RST}"
}

# ════════════════════════════════════════════════════════════════════════════
#  Меню установки и настройки (чекбоксы)
# ════════════════════════════════════════════════════════════════════════════

ORDER=(UPDATE BASE QEMU HOSTNAME TIME DISK SWAP DOCKER PORTAINER
       FAIL2BAN UNATTENDED LOGS IPV6 SSH FIREWALL)

declare -A DESC=(
    [UPDATE]="Обновление системы (apt update && upgrade)"
    [BASE]="Базовые пакеты и утилиты (mc, htop, jq, git, ...)"
    [QEMU]="QEMU Guest Agent (для VM в Proxmox)"
    [HOSTNAME]="Имя хоста"
    [TIME]="Таймзона и синхронизация времени"
    [DISK]="Диски: расширение корня на весь объём"
    [SWAP]="Swap: файл подкачки, swappiness, zram"
    [DOCKER]="Docker + Compose (+ ротация логов, + фикс обхода UFW)"
    [PORTAINER]="Portainer CE (веб-панель для Docker)"
    [FAIL2BAN]="fail2ban с рабочим jail для sshd"
    [UNATTENDED]="Автообновления безопасности"
    [LOGS]="Ограничение размера системного журнала"
    [IPV6]="IPv6: включить или отключить"
    [SSH]="SSH: ключи, пароли, root-логин, порт"
    [FIREWALL]="Firewall (UFW): политики и базовые порты"
)

declare -A FUNC=(
    [UPDATE]=mod_update      [BASE]=mod_base          [QEMU]=mod_qemu
    [HOSTNAME]=mod_hostname  [TIME]=mod_time          [DISK]=mod_disk
    [SWAP]=mod_swap          [DOCKER]=mod_docker      [PORTAINER]=mod_portainer
    [FAIL2BAN]=mod_fail2ban  [UNATTENDED]=mod_unattended
    [LOGS]=mod_logs          [IPV6]=mod_ipv6          [SSH]=mod_ssh
    [FIREWALL]=mod_firewall
)

declare -A SEL=()
reset_selection() { local k; for k in "${ORDER[@]}"; do SEL[$k]=0; done; }

show_setup_menu() {
    clear
    echo "${BLD}${BLU}╔══════════════════════════════════════════════════════════╗"
    echo "║               Установка и настройка                      ║"
    echo "╚══════════════════════════════════════════════════════════╝${RST}"
    crumbs "Быстрая настройка"
    echo
    local i=1 k mark
    for k in "${ORDER[@]}"; do
        if [[ ${SEL[$k]} == 1 ]]; then mark="${GRN}x${RST}"; else mark=" "; fi
        printf "  %2d) [%b] %s\n" "$i" "$mark" "${DESC[$k]}"
        i=$((i+1))
    done
    echo
    echo "${DIM}  Модули выполняются в порядке этого списка, а не в порядке выбора."
    echo "  Некоторые из них зададут вопросы по ходу дела.${RST}"
    echo
    echo "  ${CYN}номера через пробел${RST} — переключить    ${CYN}a${RST} — всё    ${CYN}n${RST} — ничего"
    echo "  ${CYN}Enter${RST} — запустить выбранное          ${CYN}q${RST} — назад"
    echo
}

select_steps() {
    local input token idx k
    while true; do
        show_setup_menu
        printf 'Выбор: '
        IFS= read -r input <"$TTY_IN" || input=''
        case $input in
            "")   break ;;
            q|Q)  return 2 ;;
            a|A)  for k in "${ORDER[@]}"; do SEL[$k]=1; done ;;
            n|N)  reset_selection ;;
            *)
                for token in $input; do
                    if idx=$(parse_uint "$token" 1 "${#ORDER[@]}"); then
                        idx=$((idx - 1)); k=${ORDER[$idx]}
                        SEL[$k]=$(( 1 - SEL[$k] ))
                    else
                        echo "  ${RED}Не понял: $token${RST}"; sleep 1
                    fi
                done
                ;;
        esac
    done

    local any=0
    for k in "${ORDER[@]}"; do [[ ${SEL[$k]} == 1 ]] && any=1; done
    (( any == 0 )) && { info "Ничего не выбрано."; return 1; }

    if [[ ${SEL[PORTAINER]} == 1 && ${SEL[DOCKER]} == 0 ]] && ! command -v docker &>/dev/null; then
        warn "Portainer требует Docker — добавляю модуль Docker."
        SEL[DOCKER]=1
        sleep 1.5
    fi
    return 0
}

run_selected() {
    local k fn done_list=() failed=()
    # Состояние прошлого прогона в этой же сессии не должно протекать в новый.
    # Очередь портов — исключение: её специально копят модули, отработавшие до
    # включения firewall, и разбирает модуль Firewall, возможно в другом заходе.
    PORTAINER_EDGE=0
    PORTAINER_URL=""
    clear
    for k in "${ORDER[@]}"; do
        [[ ${SEL[$k]} == 1 ]] || continue
        fn=${FUNC[$k]}
        title "${DESC[$k]}"
        log "=== модуль $k ==="
        CURRENT_MODULE=$k
        if $fn; then
            done_list+=("$k")
        else
            failed+=("$k")
            err "Модуль «${DESC[$k]}» завершился с ошибкой."
        fi
        echo
    done

    hr
    echo "${BLD}${GRN}=== Готово ===${RST}"
    # Названия из меню, а не внутренние имена модулей — на экране их нигде нет.
    if (( ${#done_list[@]} )); then
        echo "${BLD}Выполнено:${RST}"
        for k in "${done_list[@]}"; do echo "  ${GRN}✔${RST} ${DESC[$k]}"; done
    fi
    if (( ${#failed[@]} )); then
        echo "${BLD}${RED}С ошибками:${RST}"
        for k in "${failed[@]}"; do echo "  ${RED}✘${RST} ${DESC[$k]}"; done
        echo "Подробности: $LOG_FILE"
    fi
    echo
    [[ -n ${PORTAINER_URL:-} ]] && echo "Portainer: ${BLD}${PORTAINER_URL}${RST}"
    # Очередь портов разбирает модуль Firewall. Если его не выбрали, заявки
    # так и остались бы висеть молча — говорим об этом прямо.
    if (( ${#PENDING_PORTS[@]} )); then
        warn "Остались неоткрытыми порты: $(printf '%s ' "${PENDING_PORTS[@]}" | sed 's/ docker/ /g; s/ allow/ /g; s/ limit/ /g')"
        warn "UFW не был включён. Открой их в пункте «Порты и firewall» или запусти модуль Firewall."
    fi
    if [[ ${SEL[DOCKER]} == 1 && $TARGET_USER != root ]]; then
        echo "${YLW}Перелогинься под $TARGET_USER, чтобы docker работал без sudo.${RST}"
    fi
    reboot_required && warn "Системе требуется перезагрузка — раздел «Очистка и перезагрузка»."
    echo
}

# ════════════════════════════════════════════════════════════════════════════
#  Главное меню
# ════════════════════════════════════════════════════════════════════════════

header() {
    clear
    echo "${BLD}${BLU}╔══════════════════════════════════════════════════════════╗"
    echo "║   ubuntu.sh — настройка и обслуживание Ubuntu Server     ║"
    echo "╚══════════════════════════════════════════════════════════╝${RST}"
    local ufw_s docker_s
    if command -v ufw &>/dev/null; then
        ufw_active && ufw_s="${GRN}активен${RST}" || ufw_s="${YLW}выключен${RST}"
    else
        ufw_s="${DIM}нет${RST}"
    fi
    if command -v docker &>/dev/null; then
        docker_s="$(docker ps -q 2>/dev/null | wc -l) конт."
    else
        docker_s="${DIM}нет${RST}"
    fi
    printf "  %s   %s   %s\n" "$(hostname)" "$(os_pretty)" "$(uname -r)"
    printf "  IP: %-16s аптайм: %s\n" "$(primary_ip)" "$(uptime -p 2>/dev/null | sed 's/^up //')"
    printf "  диск /: %-12s память: %-14s virt: %s\n" \
        "$(df -h / | awk 'NR==2{print $5}')" \
        "$(free -h | awk '/^Mem:/{print $3"/"$2}')" \
        "$(virt_type)"
    printf "  UFW: %b   SSH: порты %s   Docker: %b\n" "$ufw_s" "$(ssh_ports_display)" "$docker_s"
    reboot_required && echo "  ${YLW}⚠ требуется перезагрузка${RST}"
    echo
}


# ── Меню по объектам ────────────────────────────────────────────────────────
# Разделы собраны по тому, чем управляешь (диск, сеть, docker), а не по типу
# действия. Прежняя раскладка разводила связанное по разным веткам: настройка
# firewall жила в «Установке», его же правила — в отдельном пункте, а откат
# сделанного — внутри «Обслуживания».

# Один модуль из общего списка, запущенный отдельно от чекбоксов.
run_one() {  # run_one КЛЮЧ
    local k=$1
    CURRENT_MODULE=$k
    title "${DESC[$k]}"
    log "=== модуль $k ==="
    if "${FUNC[$k]}"; then
        ok "Готово: ${DESC[$k]}"
    else
        err "Модуль «${DESC[$k]}» завершился с ошибкой. Подробности: $LOG_FILE"
    fi
    CURRENT_MODULE=""
}

menu_system() {
    while true; do
        clear
        echo "${BLD}${BLU}╔══════════════════════════════════════════════════════════╗"
        echo "║                        Система                           ║"
        echo "╚══════════════════════════════════════════════════════════╝${RST}"
        crumbs "Система"
        echo
        echo "  ${BLD}1)${RST} Обновить систему        ${DIM}— apt update && upgrade${RST}"
        echo "  ${BLD}2)${RST} Установленный софт      ${DIM}— что стоит, поставить, удалить${RST}"
        echo "  ${BLD}3)${RST} Базовые пакеты          ${DIM}— mc, htop, jq, git и прочее${RST}"
        echo "  ${BLD}4)${RST} Имя хоста"
        echo "  ${BLD}5)${RST} Таймзона и время"
        echo "  ${BLD}6)${RST} Автообновления безопасности"
        echo "  ${BLD}7)${RST} Размер системного журнала"
        echo "  ${BLD}8)${RST} QEMU Guest Agent        ${DIM}— для виртуальных машин${RST}"
        echo "  ${BLD}0)${RST} Назад"
        echo
        local c; ask "Выбор"; c=$REPLY_VAL
        case $c in
            1) run_one UPDATE; pause ;;
            2) mod_software ;;
            3) run_one BASE; pause ;;
            4) run_one HOSTNAME; pause ;;
            5) run_one TIME; pause ;;
            6) run_one UNATTENDED; pause ;;
            7) run_one LOGS; pause ;;
            8) run_one QEMU; pause ;;
            0|q|Q) return 0 ;;
            *) err "Неверный выбор."; sleep 1 ;;
        esac
    done
}

menu_network() {
    while true; do
        clear
        echo "${BLD}${BLU}╔══════════════════════════════════════════════════════════╗"
        echo "║                     Сеть и доступ                        ║"
        echo "╚══════════════════════════════════════════════════════════╝${RST}"
        crumbs "Сеть и доступ"
        echo
        echo "  ${BLD}1)${RST} Порты и firewall        ${DIM}— что слушает, что разрешено${RST}"
        echo "  ${BLD}2)${RST} SSH                     ${DIM}— ключи, пароли, root-логин, порт${RST}"
        echo "  ${BLD}3)${RST} Настроить firewall      ${DIM}— политики и порт SSH${RST}"
        echo "  ${BLD}4)${RST} fail2ban                ${DIM}— защита от перебора паролей${RST}"
        echo "  ${BLD}5)${RST} IPv6                    ${DIM}— включить или отключить${RST}"
        echo "  ${BLD}0)${RST} Назад"
        echo
        local c; ask "Выбор"; c=$REPLY_VAL
        case $c in
            1) port_manager ;;
            2) run_one SSH; pause ;;
            3) run_one FIREWALL; pause ;;
            4) run_one FAIL2BAN; pause ;;
            5) run_one IPV6; pause ;;
            0|q|Q) return 0 ;;
            *) err "Неверный выбор."; sleep 1 ;;
        esac
    done
}

menu_storage() {
    while true; do
        clear
        echo "${BLD}${BLU}╔══════════════════════════════════════════════════════════╗"
        echo "║                     Диски и память                       ║"
        echo "╚══════════════════════════════════════════════════════════╝${RST}"
        crumbs "Диски и память"
        echo
        echo "  ${BLD}1)${RST} Диски                   ${DIM}— расширение корня на весь объём${RST}"
        echo "  ${BLD}2)${RST} Swap                    ${DIM}— файл подкачки, swappiness, zram${RST}"
        echo "  ${BLD}0)${RST} Назад"
        echo
        local c; ask "Выбор"; c=$REPLY_VAL
        case $c in
            1) run_one DISK; pause ;;
            2) run_one SWAP; pause ;;
            0|q|Q) return 0 ;;
            *) err "Неверный выбор."; sleep 1 ;;
        esac
    done
}

menu_docker() {
    while true; do
        clear
        echo "${BLD}${BLU}╔══════════════════════════════════════════════════════════╗"
        echo "║                          Docker                          ║"
        echo "╚══════════════════════════════════════════════════════════╝${RST}"
        crumbs "Docker"
        echo
        if command -v docker &>/dev/null; then
            echo "  ${DIM}$(docker --version 2>/dev/null | sed 's/,.*//') · контейнеров запущено: $(docker ps -q 2>/dev/null | wc -l)${RST}"
            ufw_docker_fix_applied && echo "  ${DIM}фикс обхода UFW применён${RST}"
        else
            echo "  ${DIM}Docker не установлен${RST}"
        fi
        echo
        echo "  ${BLD}1)${RST} Docker                  ${DIM}— установка, ротация логов, фикс UFW${RST}"
        echo "  ${BLD}2)${RST} Portainer               ${DIM}— веб-панель, обновление, перезапуск${RST}"
        echo "  ${BLD}0)${RST} Назад"
        echo
        local c; ask "Выбор"; c=$REPLY_VAL
        case $c in
            1) run_one DOCKER; pause ;;
            2) run_one PORTAINER; pause ;;
            0|q|Q) return 0 ;;
            *) err "Неверный выбор."; sleep 1 ;;
        esac
    done
}

menu_state() {
    while true; do
        clear
        echo "${BLD}${BLU}╔══════════════════════════════════════════════════════════╗"
        echo "║                    Состояние машины                      ║"
        echo "╚══════════════════════════════════════════════════════════╝${RST}"
        crumbs "Состояние машины"
        echo
        echo "  ${BLD}1)${RST} Информация о системе"
        echo "  ${BLD}2)${RST} Проверка безопасности   ${DIM}— что открыто наружу${RST}"
        echo "  ${BLD}3)${RST} Состояние служб"
        echo "  ${BLD}4)${RST} Ресурсы                 ${DIM}— диск, память, процессы${RST}"
        echo "  ${BLD}5)${RST} Ошибки в журнале"
        echo "  ${BLD}6)${RST} fail2ban: кто в бане, разбан"
        echo "  ${BLD}0)${RST} Назад"
        echo
        local c; ask "Выбор"; c=$REPLY_VAL
        case $c in
            1) system_info; pause ;;
            2) security_audit; pause ;;
            3) maint_services; pause ;;
            4) maint_resources; pause ;;
            5) maint_logs; pause ;;
            6) maint_fail2ban; pause ;;
            0|q|Q) return 0 ;;
            *) err "Неверный выбор."; sleep 1 ;;
        esac
    done
}

menu_cleanup() {
    while true; do
        clear
        echo "${BLD}${BLU}╔══════════════════════════════════════════════════════════╗"
        echo "║                 Очистка и перезагрузка                   ║"
        echo "╚══════════════════════════════════════════════════════════╝${RST}"
        crumbs "Очистка и перезагрузка"
        echo
        reboot_required && warn "Системе требуется перезагрузка."
        echo
        echo "  ${BLD}1)${RST} Очистка                 ${DIM}— пакеты, журнал, docker${RST}"
        echo "  ${BLD}2)${RST} Перезагрузить сервер"
        echo "  ${BLD}0)${RST} Назад"
        echo
        local c; ask "Выбор"; c=$REPLY_VAL
        case $c in
            1) maint_clean; pause ;;
            2) maint_reboot; pause ;;
            0|q|Q) return 0 ;;
            *) err "Неверный выбор."; sleep 1 ;;
        esac
    done
}

# ── Фоновые обращения и текущие соединения ──────────────────────────────────

activity_unit() {
    local data load enabled active
    data=$(systemctl show "$1" -p LoadState -p UnitFileState -p ActiveState 2>/dev/null) || true
    load=$(sed -n 's/^LoadState=//p' <<<"$data")
    enabled=$(sed -n 's/^UnitFileState=//p' <<<"$data")
    active=$(sed -n 's/^ActiveState=//p' <<<"$data")
    case $load in
        not-found) echo 'не установлен'; return ;;
        loaded|masked) ;;
        *) echo 'не удалось определить'; return ;;
    esac
    case $enabled in
        enabled) enabled='включён' ;;
        disabled) enabled='выключен' ;;
        masked) enabled='замаскирован' ;;
        *) enabled="автозапуск: ${enabled:-неизвестно}" ;;
    esac
    case $active in
        active) active='активен' ;;
        inactive) active='неактивен' ;;
        failed) active='ошибка' ;;
        *) active=${active:-неизвестно} ;;
    esac
    printf '%s; %s\n' "$enabled" "$active"
}

activity_value() {
    # Не исполняем shell-конфиг: сложное выражение остаётся неизвестным значением.
    [[ -f $1 && -r $1 ]] || return 1
    awk -v key="$2" '
        $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
            sub(/^[^=]*=[[:space:]]*/, ""); sub(/[[:space:]]*#.*/, "")
            gsub(/^[[:space:]"\047]+|[[:space:]"\047]+$/, ""); value=$0; found=1
        }
        END { if (found) print value; else exit 1 }
    ' "$1"
}

activity_bool() {
    case ${1:-} in
        1|True|true|yes) echo 'включено' ;;
        0|False|false|no) echo 'выключено' ;;
        *) echo 'не удалось определить' ;;
    esac
}

activity_set_value() {
    local f=$1 key=$2 value=$3 content
    [[ -f $f && ! -L $f ]] || { err "$f — нет обычного файла; настройка не изменена."; return 1; }
    content=$(awk -v key="$key" -v value="$value" '
        $0 ~ "^[[:space:]]*" key "[[:space:]]*=" { next }
        { print }
        END { print key "=" value }
    ' "$f") || return 1
    file_write "$f" <<<"$content" || return 1
    [[ $(activity_value "$f" "$key") == "$value" ]]
}

activity_switch() {
    echo "  ${BLD}1)${RST} Включить    ${BLD}2)${RST} Выключить    ${BLD}0)${RST} Назад"
    ask 'Выбор'
    case $REPLY_VAL in
        1) ACTIVITY_TARGET=1 ;;
        2) ACTIVITY_TARGET=0 ;;
        *) return 1 ;;
    esac
    ask_yn 'Применить выбранное изменение?'
}

activity_timer_apply() {
    local unit=$1 target=$2 load enabled active service=${1%.timer}.service
    load=$(systemctl show "$unit" -p LoadState --value 2>/dev/null)
    [[ $load == loaded ]] || { err "$unit: отсутствует, замаскирован или недоступен."; return 1; }
    if [[ $target == 1 ]]; then
        run systemctl enable --now "$unit" || return 1
    else
        run systemctl disable --now "$unit" || return 1
        # Остановка одного таймера не останавливает уже начатую загрузку.
        if [[ $(systemctl show "$service" -p LoadState --value 2>/dev/null) == loaded ]]; then
            run systemctl stop "$service" || return 1
        fi
    fi
    enabled=$(systemctl show "$unit" -p UnitFileState --value 2>/dev/null)
    active=$(systemctl show "$unit" -p ActiveState --value 2>/dev/null)
    if [[ $target == 1 && $enabled == enabled && $active == active ]] ||
       [[ $target == 0 && $enabled == disabled && $active == inactive ]]; then
        ok "$unit: $(activity_unit "$unit")"
    elif [[ $target == 1 && $enabled == enabled && $active == inactive &&
            $(systemctl show "$unit" -p ConditionResult --value 2>/dev/null) == no ]]; then
        warn "$unit включён, но условие запуска systemd не выполнено."
        [[ $unit == apport-autoreport.timer ]] && info 'Автоотправка Apport требует /var/lib/apport/autoreport; скрипт этот флаг не создаёт.'
        return 0
    else
        err "$unit: ожидаемое состояние не подтверждено — $(activity_unit "$unit")"; return 1
    fi
}

activity_snap_list() {
    local out
    ACTIVITY_SNAPS=()
    out=$(LC_ALL=C timeout 10 snap list 2>&1) || return 1
    [[ $out == 'No snaps are installed yet.'* ]] && return 0
    [[ $out == Name[[:space:]]* ]] || return 1
    mapfile -t ACTIVITY_SNAPS < <(awk 'NR>1 && NF {print $1}' <<<"$out")
}

activity_purge() {
    local pkg=$1 victims p
    pkg_installed "$pkg" || { info "$pkg не установлен."; return; }
    victims=$(purge_victims "$pkg") && grep -Fxq "$pkg" <<<"$victims" || {
        err 'APT не подтвердил последствия удаления. Отмена.'; return 1;
    }
    while IFS= read -r p; do
        if pkg_protected "$p"; then err "Удаление затронет защищённый пакет $p. Отмена."; return 1; fi
    done <<<"$victims"
    printf 'Будут удалены пакеты и их настройки:\n%s\n' "$victims"
    confirm_danger "Удалить $pkg и перечисленные зависимости?" || return 0
    # Список мог измениться, пока человек читал подтверждение.
    if [[ $pkg == snapd ]]; then
        activity_snap_list && (( ${#ACTIVITY_SNAPS[@]} == 0 )) || {
            err 'Отсутствие снапов не подтверждено. Удаление отменено.'; return 1;
        }
    fi
    run apt_get purge -y "$pkg" || return 1
    if pkg_installed "$pkg"; then err "$pkg остался установлен."; return 1; fi
    while IFS= read -r p; do
        pkg_installed "$p" || manifest_del "$p"
    done <<<"$victims"
    ok "$pkg удалён."
}

activity_snap() {
    pkg_installed snapd || { info 'snapd не установлен.'; return; }
    activity_snap_list || { err 'Не удалось получить список снапов; изменения недоступны.'; return 1; }
    echo "Установлено снапов: ${#ACTIVITY_SNAPS[@]} ${ACTIVITY_SNAPS[*]}"
    LC_ALL=C timeout 10 snap refresh --time || { err 'Расписание не удалось прочитать.'; return 1; }
    echo "  ${BLD}1)${RST} Обновлять ночью, 00:00–04:00 по времени машины"
    echo "  ${BLD}2)${RST} Приостановить автообновление на 1–90 дней"
    echo "  ${BLD}3)${RST} Снять общую паузу автообновлений"
    echo "  ${BLD}4)${RST} Вернуть стандартное расписание"
    (( ${#ACTIVITY_SNAPS[@]} == 0 )) && echo "  ${BLD}d)${RST} Удалить snapd (снапов нет)"
    echo "  ${BLD}0)${RST} Назад"
    echo 'Ручной snap refresh может обновлять и во время общей паузы.'
    local c days actual schedule hold_until before after
    ask 'Выбор'; c=$REPLY_VAL
    case $c in
        1)
            ask_yn 'Установить ночное окно? Имеющаяся пауза сохранится.' || return
            run snap set system refresh.timer=00:00-04:00 || return 1
            actual=$(timeout 10 snap get system refresh.timer 2>/dev/null)
            [[ $actual == 00:00-04:00 ]] || { err 'Ночное окно не подтверждено.'; return 1; }
            ok 'Ночное окно записано.' ;;
        2)
            ask 'Дней (1–90, Enter — отмена)'; [[ -n $REPLY_VAL ]] || return
            days=$(parse_uint "$REPLY_VAL" 1 90) || { err 'Нужно число от 1 до 90.'; return 1; }
            ask_yn "Приостановить автообновления на $(plural "$days" день дня дней)?" || return
            before=$(date +%s)
            # У snap refresh --hold длительность в часах, суффикса d нет.
            run snap refresh --hold="$((days * 24))h" || return 1 ;;
        3)
            ask_yn 'Снять общую паузу? Обновления снова смогут запускаться по расписанию.' || return
            run snap refresh --unhold || return 1 ;;
        4)
            ask_yn 'Удалить настройку окна и использовать расписание snapd по умолчанию?' || return
            run snap unset system refresh.timer || return 1 ;;
        d|D) (( ${#ACTIVITY_SNAPS[@]} == 0 )) && activity_purge snapd; return ;;
        *) return ;;
    esac
    # Показываем фактический hold и расписание, включая паузы, заданные вне скрипта.
    echo 'Расписание после команды (timer — окно, hold — пауза, next — следующий запуск):'
    schedule=$(LC_ALL=C timeout 10 snap refresh --time --abs-time) || { err 'Не удалось проверить расписание после изменения.'; return 1; }
    printf '%s\n' "$schedule"
    case $c in
        2)
            actual=$(awk '$1=="hold:" {print $2}' <<<"$schedule")
            hold_until=$(date -d "$actual" +%s 2>/dev/null) || { err 'Срок паузы не удалось проверить.'; return 1; }
            after=$(date +%s)
            # snap --time округляет дату до минуты.
            (( hold_until >= before + days*86400 - 60 && hold_until <= after + days*86400 )) || {
                err 'Фактический срок паузы отличается от запрошенного.'; return 1;
            }
            ok 'Срок паузы подтверждён.' ;;
        3)
            if grep -q '^hold:' <<<"$schedule"; then err 'В расписании осталась пауза.'; return 1; fi
            grep -q '^timer:' <<<"$schedule" || { err 'Ответ snap не содержит расписания.'; return 1; }
            ok 'Общая пауза снята. Индивидуальные паузы снапов не менялись.' ;;
        4)
            actual=$(LC_ALL=C timeout 10 snap get system refresh.timer 2>&1)
            [[ $actual == *'has no "refresh.timer" configuration option'* ]] || {
                err 'Удаление настройки окна не подтверждено.'; return 1;
            }
            ok 'Пользовательское окно удалено.' ;;
    esac
}

activity_cloud() {
    local flag=/etc/cloud/cloud-init.disabled
    pkg_installed cloud-init || { info 'cloud-init не установлен.'; return; }
    if [[ -e $flag || -L $flag ]]; then
        echo 'Флаг запрещает cloud-init запускаться при загрузке.'
        ask_yn 'Убрать флаг? При следующей загрузке cloud-init сможет применить настройки источника данных.' || return
        [[ -f $flag && ! -L $flag ]] || { err 'Флаг — не обычный файл; автоматическое удаление отменено.'; return 1; }
        backup_file "$flag" >/dev/null && run rm -- "$flag" && file_manifest_del "$flag" || return 1
        [[ ! -e $flag ]] && ok 'Флаг удалён. Остальные условия запуска cloud-init не менялись.'
    else
        echo 'На будущих клонах отключённый cloud-init не применит ключи, пароль и сеть из Proxmox.'
        echo "  ${BLD}1)${RST} Это конечная машина    ${BLD}2)${RST} Будущий шаблон    ${BLD}0)${RST} Назад"
        ask 'Назначение машины'
        [[ $REPLY_VAL == 1 ]] || { info 'cloud-init не изменён.'; return; }
        ask_yn 'Запретить cloud-init при следующих загрузках этой машины?' || return
        file_write "$flag" </dev/null || return 1
        [[ -f $flag ]] && ok 'Флаг создан. Уже запущенные задачи cloud-init продолжают работать.'
    fi
}

activity_action() {
    local c=$1 ACTIVITY_TARGET=0 config key timer value
    activity_heading
    case $c in
        1)
            title 'Новости MOTD'
            echo 'Новости в MOTD: загрузка по таймеру, при входе обычно показывается кеш.'
            config=/etc/default/motd-news; key=ENABLED; timer=motd-news.timer ;;
        2)
            command -v pro >/dev/null || { info 'Ubuntu Pro не установлен.'; return; }
            title 'Новости apt'
            echo 'Меняются только APT News. ESM и фоновые проверки Ubuntu Pro сохраняются.'
            activity_switch || return
            value=false; [[ $ACTIVITY_TARGET == 1 ]] && value=true
            run pro config set "apt_news=$value" || return 1
            config=$(timeout 10 pro config show 2>/dev/null) || { err 'Не удалось проверить настройку.'; return 1; }
            key=$(awk '$1=="apt_news" {print tolower($2)}' <<<"$config")
            [[ $key == "$value" ]] && ok "Новости apt: $(activity_bool "$key")" || { err 'Настройка не подтверждена.'; return 1; }
            return ;;
        3) title 'Данные пакетов'; echo 'Дополнительные данные пакетов: package-data-downloader. Обновления пакетов — в 2 → 6.'; timer=update-notifier-download.timer ;;
        4) title 'Новый выпуск Ubuntu'; echo 'Проверка новой версии Ubuntu для MOTD. Счётчик обновлений пакетов — отдельный механизм.'; timer=update-notifier-motd.timer ;;
        5) title 'Метаданные прошивок'; echo 'Метаданные прошивок: без обновления метаданных сведения о доступных прошивках могут устареть.'; timer=fwupd-refresh.timer ;;
        6)
            title 'Отчёты Apport'
            echo 'Apport: сбор отчётов о падениях и таймер автоотправки. Другие механизмы дампов не меняются.'
            echo "Служба сбора: $(activity_unit apport.service)"
            echo 'Для автоотправки дополнительно нужен /var/lib/apport/autoreport; скрипт его не создаёт.'
            config=/etc/default/apport; key=enabled; timer=apport-autoreport.timer ;;
        7)
            title 'Статистика пакетов'
            pkg_installed popularity-contest || { info 'popularity-contest не установлен.'; return; }
            echo "  ${BLD}d)${RST} Удалить popularity-contest и его настройки    ${BLD}0)${RST} Назад"
            ask 'Выбор'; [[ $REPLY_VAL == d || $REPLY_VAL == D ]] && activity_purge popularity-contest
            return ;;
        8) title 'Snap'; activity_snap; return ;;
        9) title 'cloud-init'; activity_cloud; return ;;
        *) return ;;
    esac
    echo "Таймер: $(activity_unit "$timer")"
    [[ -n ${config:-} ]] && echo "Настройка: $(activity_bool "$(activity_value "$config" "$key")")"
    [[ $(systemctl show "$timer" -p LoadState --value 2>/dev/null) == loaded ]] || {
        warn 'Таймер отсутствует или недоступен; изменение не предлагается.'; return;
    }
    activity_switch || return
    if [[ -n ${config:-} ]]; then
        activity_set_value "$config" "$key" "$ACTIVITY_TARGET" || { err 'Настройка не записана.'; return 1; }
    fi
    activity_timer_apply "$timer" "$ACTIVITY_TARGET" || { warn 'Изменение выполнено не полностью; проверь состояние на экране.'; return 1; }
    if [[ $c == 6 ]]; then
        if [[ $ACTIVITY_TARGET == 1 ]]; then run systemctl enable --now apport.service || return 1
        else run systemctl disable --now apport.service || return 1; fi
        echo "Apport: $(activity_unit apport.service)"
    fi
}

activity_connections() {
    local raw
    raw=$(ss -H -ntup 2>/dev/null) || { echo 'Не удалось получить соединения (ss).'; return; }
    # Наличие сокета не говорит, кто начал обмен и что именно передаётся.
    printf '%s\n' "$raw" | LC_ALL=C awk -v full="${1:-0}" '
        NF>=6 && $6 !~ /^(\*|0\.0\.0\.0|\[::\]):\*$/ {
            process="?"; if (match($0, /"[^"]+"/)) process=substr($0,RSTART+1,RLENGTH-2)
            gsub(/[^ -~]/,"?",process)
            if (full) printf "%s %s %s %s %s\n",$1,process,$5,$6,$2
            else {
                localaddr=$5; peer=$6
                if (length(localaddr)>24) localaddr=substr(localaddr,1,21) "..."
                if (length(peer)>24) peer=substr(peer,1,21) "..."
                printf "%-4s %-14.14s %-24s %-24s %s\n",$1,process,localaddr,peer,$2
            }
        }
    '
}

activity_heading() {
    clear
    echo "${BLD}${BLU}╔══════════════════════════════════════════════════════════╗"
    echo "║                    Сетевая активность                    ║"
    echo "╚══════════════════════════════════════════════════════════╝${RST}"
    crumbs "Сетевая активность" "$@"
}

activity_menu_line() {
    local key=$1 label=$2 state=$3 width=$((ACTIVITY_COLS - 33))
    (( width > 0 )) || width=1
    printf '  %s%s)%s ' "$BLD" "$key" "$RST"
    pad "$label" 24
    printf ' %s— %s%s\n' "$DIM" "${state:0:width}" "$RST"
}

activity_screen() {
    local pro_data='' news='не установлен' snaps='не установлен' cloud='не установлен' pop='не установлен'
    local rows cols
    if command -v pro >/dev/null; then
        pro_data=$(timeout 10 pro config show 2>/dev/null) || pro_data=''
        news=$(activity_bool "$(awk '$1=="apt_news" {print $2}' <<<"$pro_data")")
    fi
    if pkg_installed snapd; then
        if activity_snap_list; then snaps="установлено снапов: ${#ACTIVITY_SNAPS[@]}"; else snaps='список недоступен'; fi
    fi
    pkg_installed popularity-contest && pop="участие: $(activity_bool "$(activity_value /etc/popularity-contest.conf PARTICIPATE)")"
    if pkg_installed cloud-init; then
        if [[ -e /etc/cloud/cloud-init.disabled || -L /etc/cloud/cloud-init.disabled ]]; then cloud='запрещён флагом'
        else cloud='запрещающего флага нет'; fi
    fi
    read -r rows cols < <(stty size <"$TTY_IN" 2>/dev/null) || true
    [[ ${cols:-} =~ ^[0-9]+$ ]] || cols=80
    [[ ${rows:-} =~ ^[0-9]+$ ]] || rows=24
    ACTIVITY_COLS=$cols
    activity_heading
    # На коротком экране оставляем место соединениям, убирая только пустые строки.
    (( rows >= 28 )) && echo
    activity_menu_line 1 'Новости MOTD' "$(activity_bool "$(activity_value /etc/default/motd-news ENABLED)"); $(activity_unit motd-news.timer)"
    activity_menu_line 2 'Новости apt' "$news"
    activity_menu_line 3 'Данные пакетов' "$(activity_unit update-notifier-download.timer)"
    activity_menu_line 4 'Новый выпуск Ubuntu' "$(activity_unit update-notifier-motd.timer)"
    activity_menu_line 5 'Метаданные прошивок' "$(activity_unit fwupd-refresh.timer)"
    activity_menu_line 6 'Apport' "$(activity_bool "$(activity_value /etc/default/apport enabled)"); $(activity_unit apport.service)"
    activity_menu_line 7 'Статистика пакетов' "$pop"
    activity_menu_line 8 'Snap' "$snaps"
    activity_menu_line 9 'cloud-init' "$cloud"
    activity_menu_line p 'Ubuntu Pro' "$(activity_unit ua-timer.timer); просмотр"
    activity_menu_line a 'Обновления APT' 'просмотр; управление в 2 → 6'
    if (( rows >= 28 )); then
        echo
        echo "  ${BLD}r)${RST} Обновить состояния      ${BLD}c)${RST} Адреса соединений целиком"
        echo "  ${BLD}0)${RST} Назад"
        ACTIVITY_PROMPT_ROW=22
    else
        echo "  ${BLD}r)${RST} Обновить    ${BLD}c)${RST} Адреса целиком    ${BLD}0)${RST} Назад"
        ACTIVITY_PROMPT_ROW=19
    fi
    echo
    printf 'Выбор: '

}

activity_read() {
    local rows=24 cols=80 size key buffer='' rc snapshot line i count first=$((ACTIVITY_PROMPT_ROW + 2))
    if ! terminal_is_interactive || [[ ! -t 1 || ${TERM:-dumb} == dumb ]]; then
        echo; activity_connections; ask 'Выбор'; return
    fi
    # Нет фонового писателя: при вводе и в подтверждениях экран неподвижен.
    while true; do
        size=$(stty size <"$TTY_IN" 2>/dev/null)
        read -r rows cols <<<"$size"
        [[ $rows =~ ^[0-9]+$ && $cols =~ ^[0-9]+$ ]] || { rows=24; cols=80; }
        if (( rows > first && cols >= 80 )) && [[ -z $buffer ]]; then
            snapshot=$(activity_connections)
            printf '\033[%s;1H\033[2K%s%s%s' "$((first-1))" "${BLD}${CYN}" 'PROTO ПРОЦЕСС        ЛОКАЛЬНЫЙ АДРЕС          УДАЛЁННЫЙ АДРЕС          СОСТОЯНИЕ' "$RST"
            i=$first; count=0
            while IFS= read -r line; do
                [[ -n $line ]] || continue
                count=$((count+1))
                if (( i < rows )); then
                    printf '\033[%s;1H\033[2K%s' "$i" "${line:0:cols-1}"
                    i=$((i+1))
                fi
            done <<<"$snapshot"
            while (( i < rows )); do printf '\033[%s;1H\033[2K' "$i"; i=$((i+1)); done
            line="Всего: $count; показано: $((count < rows-first ? count : rows-first)). Обновление — 3 с; короткие обращения могут быть пропущены."
            printf '\033[%s;1H\033[2K%s%s%s' "$rows" "$DIM" "${line:0:cols-1}" "$RST"
            printf '\033[%s;1H\033[2KВыбор: ' "$ACTIVITY_PROMPT_ROW"
        fi
        if [[ -z $buffer ]]; then IFS= LC_ALL=C read -r -s -n 1 -t 3 key <"$TTY_IN"; rc=$?
        else IFS= LC_ALL=C read -r -s -n 1 key <"$TTY_IN"; rc=$?; fi
        (( rc > 128 )) && continue
        if (( rc != 0 )); then REPLY_VAL=0; echo; return; fi
        case $key in
            '') REPLY_VAL=$buffer; echo; return ;;
            $'\177'|$'\b') [[ -n $buffer ]] && { buffer=${buffer%?}; printf '\b \b'; } ;;
            [0-9aAcCpPrRqQ]) if (( ${#buffer} < 2 )); then buffer+=$key; printf '%s' "$key"; fi ;;
            *) printf '\a' ;;
        esac
    done
}

menu_activity() {
    local c data ACTIVITY_COLS=80 ACTIVITY_PROMPT_ROW=19
    while true; do
        activity_screen
        activity_read; c=$REPLY_VAL
        case $c in
            0|q|Q|'') return ;;
            r|R) continue ;;
            c|C) activity_heading 'Соединения'; title 'Текущие соединения'; echo 'PROTO ПРОЦЕСС ЛОКАЛЬНЫЙ_АДРЕС УДАЛЁННЫЙ_АДРЕС СОСТОЯНИЕ'; activity_connections 1 ;;
            p|P)
                activity_heading 'Ubuntu Pro'
                title 'Фоновые проверки Ubuntu Pro'
                echo "Ubuntu Pro: $(activity_unit ua-timer.timer)"
                data=$(timeout 10 pro config show 2>/dev/null) || data=''
                if [[ -n $data ]]; then
                    awk '$1=="update_messaging_timer" {print "Проверка сообщений: каждые " $2 " секунд"} $1=="metering_timer" {print "Учёт использования: каждые " $2 " секунд"}' <<<"$data"
                else warn 'Интервалы не удалось определить.'; fi
                echo 'Отключение новостей apt не отключает эти проверки.' ;;
            a|A)
                activity_heading 'Обновления APT'
                title 'Периодические задачи APT'
                echo "apt-daily: $(activity_unit apt-daily.timer)"
                echo "apt-daily-upgrade: $(activity_unit apt-daily-upgrade.timer)"
                if data=$(apt-config dump 2>/dev/null); then
                    echo 'Настройки периодических действий APT (отсутствующий ключ здесь не означает 0):'
                    printf '%s\n' "$data" | awk '/^APT::Periodic/ {print}'
                else warn 'Не удалось прочитать настройки APT.'; fi
                echo 'Управление автообновлениями: 2 → 6. Таймер и разрешённые ему действия — разные настройки.' ;;
            [1-9]) activity_action "$c" ;;
            *) warn 'Неверный выбор.' ;;
        esac
        pause
    done
}

main_menu() {
    while true; do
        header
        echo "  ${BLD}1)${RST} Быстрая настройка       ${DIM}— всё нужное для свежей машины, галочками${RST}"
        echo "  ${BLD}2)${RST} Система                 ${DIM}— обновления, софт, имя, время, журнал${RST}"
        echo "  ${BLD}3)${RST} Сеть и доступ           ${DIM}— порты, firewall, SSH, fail2ban, IPv6${RST}"
        echo "  ${BLD}4)${RST} Диски и память          ${DIM}— расширение корня, swap, zram${RST}"
        echo "  ${BLD}5)${RST} Docker                  ${DIM}— docker, Portainer, фикс обхода UFW${RST}"
        echo "  ${BLD}6)${RST} Состояние машины        ${DIM}— информация, безопасность, службы, логи${RST}"
        echo "  ${BLD}7)${RST} Что изменил скрипт      ${DIM}— свои файлы, копии, откат${RST}"
        echo "  ${BLD}8)${RST} Очистка и перезагрузка"
        echo "  ${BLD}9)${RST} Сетевая активность      ${DIM}— фоновые задачи и текущие соединения${RST}"
        echo "  ${BLD}0)${RST} Выход"
        echo
        local c
        ask "Выбор"; c=$REPLY_VAL
        case $c in
            1)  reset_selection
                select_steps
                case $? in
                    0) run_selected; pause ;;   # выбрано и выполнено
                    1) pause ;;                 # ничего не выбрано
                esac                            # 2 — вышли по q, молча назад
                ;;
            2) menu_system ;;
            3) menu_network ;;
            4) menu_storage ;;
            5) menu_docker ;;
            6) menu_state ;;
            7) maint_changes ;;
            8) menu_cleanup ;;
            9) menu_activity ;;
            0|q|Q) echo "${BLD}Выход.${RST}"; log "=== завершение ==="; exit 0 ;;
            *) err "Неверный выбор."; sleep 1 ;;
        esac
    done
}

main() {
    require_root "$@"
    init_log
    terminal_init || warn "Не удалось включить UTF-8 для терминала; при стирании кириллицы возможны остатки."
    if [[ ! -f /etc/debian_version ]]; then
        warn "Это не Debian/Ubuntu — часть модулей работать не будет."
        ask_yn "Продолжить?" || exit 1
    fi
    reset_selection
    main_menu
}

main "$@"
