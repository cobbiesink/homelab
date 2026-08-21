#!/usr/bin/env bash
# Segunda cópia dos backups num SSD ligado por USB, sempre presente.
#
# PORQUE: hoje o restic só escreve para a Backblaze B2. Isso protege de incêndio e de roubo,
# mas um restauro de 160 GB depende da internet e do custo de saída. Um disco em casa faz o
# restauro em minutos e é independente da conta na nuvem.
#
# DESENHO: repositório restic PRÓPRIO no disco (não um espelho do da B2). Duas cópias que
# partilham histórico não são duas cópias: um "forget" mal dado propaga-se. Assim, cada uma
# aguenta-se sozinha.
#
# USO:
#   sudo ./setup-local-backup.sh --list                 mostra os discos candidatos
#   sudo ./setup-local-backup.sh /dev/sdX               usa um disco JÁ formatado e com dados
#   sudo ./setup-local-backup.sh /dev/sdX --format      APAGA o disco e formata ext4
#
# Nada é destrutivo sem --format e sem escrever a confirmação à mão.
set -euo pipefail

MOUNT=/mnt/backup
LABEL=homelab-backup
REPO="$MOUNT/restic"
STATE=/var/lib/homelab-dashboard/local-backup.json   # o dashboard lê isto
MAIN=/usr/local/sbin/homelab-backup.sh

die(){ echo "erro: $*" >&2; exit 1; }
# le a password escrita dentro de um script/env e tira-lhe as aspas, sejam simples ou duplas
read_inline_pw(){ grep -oP '^\s*(export\s+)?RESTIC_PASSWORD=\K.*' "$1" | head -1 | sed -e "s/^[\"']//" -e "s/[\"']$//"; }
[ "$(id -u)" = 0 ] || die "corre com sudo"

sysdisk=$(lsblk -no PKNAME "$(findmnt -no SOURCE /)" 2>/dev/null || true)
sysdisk=${sysdisk:-$(lsblk -no NAME,MOUNTPOINT | awk '$2=="/"{print $1}')}

list_candidates(){
  echo "discos externos encontrados (o disco de sistema é /dev/${sysdisk} e está excluído):"
  echo
  lsblk -dno NAME,SIZE,TRAN,MODEL | while read -r name size tran model; do
    [ "$name" = "$sysdisk" ] && continue
    case "$tran" in usb|"") ;; *) [ "$tran" = "usb" ] || continue ;; esac
    printf "  /dev/%-8s %-8s %-6s %s\n" "$name" "$size" "$tran" "$model"
  done
  echo
  echo "depois: sudo $0 /dev/sdX --format     (apaga o disco)"
}

[ $# -eq 0 ] && { list_candidates; exit 0; }
[ "$1" = "--list" ] && { list_candidates; exit 0; }

DEV="$1"; shift
DO_FORMAT=0
[ "${1:-}" = "--format" ] && DO_FORMAT=1

[ -b "$DEV" ] || die "$DEV não é um dispositivo de blocos"
base=$(basename "$DEV")
[ "$base" = "$sysdisk" ] && die "$DEV é o disco de sistema. não."
case "$DEV" in *"$sysdisk"*) die "$DEV faz parte do disco de sistema. não." ;; esac

tran=$(lsblk -dno TRAN "$DEV" || true)
size=$(lsblk -dno SIZE "$DEV" || true)
model=$(lsblk -dno MODEL "$DEV" || true)
echo "disco: $DEV  ($size, $tran, $model)"

# --- formatar, só a pedido e com confirmação escrita ---------------------------------------
if [ "$DO_FORMAT" = 1 ]; then
  echo
  echo "ISTO APAGA TUDO o que está em $DEV, incluindo partições existentes:"
  lsblk "$DEV"
  echo
  read -r -p 'escreve APAGAR para confirmar: ' ans
  [ "$ans" = "APAGAR" ] || die "não confirmado, nada foi tocado"
  umount "${DEV}"* 2>/dev/null || true
  wipefs -a "$DEV"
  sgdisk --zap-all "$DEV" >/dev/null 2>&1 || true
  parted -s "$DEV" mklabel gpt mkpart primary ext4 1MiB 100%
  sleep 2
  part="${DEV}1"; [ -b "$part" ] || part="${DEV}p1"
  mkfs.ext4 -q -L "$LABEL" -m 0 "$part"        # -m 0: sem reserva de 5% para root, é um disco de dados
  echo "formatado: $part"
else
  part="${DEV}1"; [ -b "$part" ] || part="${DEV}p1"; [ -b "$part" ] || part="$DEV"
  echo "a usar a partição existente $part (sem formatar)"
fi

UUID=$(blkid -s UUID -o value "$part") || die "sem UUID em $part"

# --- montar de forma estável ---------------------------------------------------------------
mkdir -p "$MOUNT"
if ! grep -q "$UUID" /etc/fstab; then
  # nofail + timeout: o servidor arranca à mesma se o disco estiver desligado ou avariado
  printf 'UUID=%s  %s  ext4  defaults,noatime,nofail,x-systemd.device-timeout=10s  0  2\n' \
    "$UUID" "$MOUNT" >> /etc/fstab
  echo "fstab: entrada criada por UUID (nofail)"
fi
systemctl daemon-reload
mountpoint -q "$MOUNT" || mount "$MOUNT"
mountpoint -q "$MOUNT" || die "não consegui montar $MOUNT"
df -h "$MOUNT" | tail -1

# --- impedir que o disco adormeça a meio de um backup --------------------------------------
cat > /etc/udev/rules.d/50-backup-no-autosuspend.rules <<EOF
# o SSD de backup não pode entrar em suspensão: o restic apanha erros de I/O a meio
ACTION=="add", SUBSYSTEM=="usb", ATTR{power/autosuspend}="-1", ATTR{power/control}="on"
EOF
udevadm control --reload-rules 2>/dev/null || true
echo "udev: autosuspend do USB desligado"

# --- password do restic: a MESMA do backup existente -----------------------------------------
# Procura por esta ordem: variável passada à mão, ficheiros conhecidos, o que o script
# principal usa, e por fim a password escrita dentro do próprio script. Nesse último caso
# extrai-se UMA vez para /root/.restic-password (600, só root), e daí em diante tudo usa um
# ficheiro. Guardar o segredo num sítio previsível vale mais do que o malabarismo de o ler
# de dentro do outro script em cada corrida.
PWFILE="${RESTIC_PASSWORD_FILE:-}"
if [ -z "$PWFILE" ]; then
  for f in /root/.restic-password /etc/restic-password /root/.config/restic/password \
           /root/.restic-pass /etc/restic/password; do
    [ -f "$f" ] && PWFILE="$f" && break
  done
fi
# ficheiros de ambiente do restic (o script principal faz source deles). O do destino actual
# primeiro: b2 é para onde o backup vai desde 2026-08-04.
if [ -z "$PWFILE" ]; then
  for ef in /root/.config/restic/*b2*.env /root/.config/restic/*.env /etc/restic/*.env; do
    [ -f "$ef" ] || continue
    cand=$(grep -oP 'RESTIC_PASSWORD_FILE=\K.*' "$ef" | head -1 | tr -d '"' || true)
    [ -n "$cand" ] && [ -f "$cand" ] && PWFILE="$cand" && echo "password: $PWFILE (via $ef)" && break
    if pw=$(read_inline_pw "$ef") && [ -n "$pw" ]; then
      printf '%s' "$pw" > /root/.restic-password; chmod 600 /root/.restic-password
      PWFILE=/root/.restic-password
      echo "password lida de $ef e guardada em $PWFILE (600, só root)"
      break
    fi
  done
fi
if [ -z "$PWFILE" ] && [ -f "$MAIN" ]; then
  for pat in 'RESTIC_PASSWORD_FILE=\K[^ "]+' '--password-file[= ]\K[^ "]+'; do
    cand=$(grep -oP "$pat" "$MAIN" | head -1 || true)
    [ -n "$cand" ] && [ -f "$cand" ] && PWFILE="$cand" && break
  done
fi
if [ -z "$PWFILE" ]; then
  for ef in $(systemctl show homelab-backup.service -p EnvironmentFile --value 2>/dev/null | tr ' ' '\n' | sed 's/^-//' | grep -v '^$'); do
    [ -f "$ef" ] || continue
    cand=$(grep -oP 'RESTIC_PASSWORD_FILE=\K.*' "$ef" | head -1 | tr -d '"' || true)
    [ -n "$cand" ] && [ -f "$cand" ] && PWFILE="$cand" && break
    if pw=$(read_inline_pw "$ef") && [ -n "$pw" ]; then
      printf '%s' "$pw" > /root/.restic-password; chmod 600 /root/.restic-password
      PWFILE=/root/.restic-password
      echo "password extraída de $ef para $PWFILE (600, só root)"
      break
    fi
  done
fi
if [ -z "$PWFILE" ] && [ -f "$MAIN" ]; then
  if pw=$(read_inline_pw "$MAIN") && [ -n "$pw" ]; then
    printf '%s' "$pw" > /root/.restic-password; chmod 600 /root/.restic-password
    PWFILE=/root/.restic-password
    echo "password extraída de $MAIN para $PWFILE (600, só root)"
  fi
fi
[ -n "$PWFILE" ] || die "não encontrei a password do restic.
  vê como o backup actual a obtém:   sudo grep -nE 'RESTIC_PASSWORD|password-file' $MAIN
  e volta a correr com:              sudo RESTIC_PASSWORD_FILE=/caminho/do/ficheiro $0 $DEV"
echo "password do restic: $PWFILE (a mesma do backup para a nuvem)"
echo "AVISO: guarda uma cópia dessa password FORA de casa. Sem ela os dois backups são lixo cifrado."

# --- repositório local ------------------------------------------------------------------------
export RESTIC_PASSWORD_FILE="$PWFILE"
if restic -r "$REPO" snapshots >/dev/null 2>&1; then
  echo "repositório já existe em $REPO"
else
  restic -r "$REPO" init
  echo "repositório criado em $REPO"
fi

# --- o que copiar: exactamente o mesmo que vai para a nuvem ---------------------------------
# A fonte de verdade e o REPOSITORIO remoto: o ultimo snapshot sabe que caminhos foram
# copiados. Adivinhar por regex a partir do script principal deu um "caminho" chamado ===,
# apanhado de um echo (2026-08-11).
PATHS=""
for ef in /root/.config/restic/*b2*.env /root/.config/restic/*.env; do
  [ -f "$ef" ] || continue
  PATHS=$( set -a; . "$ef" >/dev/null 2>&1; set +a
           restic snapshots --latest 1 --json 2>/dev/null \
           | grep -oP '"paths":\[\K[^]]*' | head -1 | tr ',' '\n' | tr -d '"' | grep '^/' | tr '\n' ' ' )
  [ -n "$PATHS" ] && echo "caminhos lidos do ultimo snapshot ($(basename "$ef"))" && break
done
# so caminhos ABSOLUTOS que existam mesmo. Isto e a rede de seguranca: qualquer lixo que
# venha de um parsing (=== e afins) fica de fora em vez de rebentar a corrida toda.
KEEP=""
for d in $PATHS; do
  case "$d" in
    /*) if [ -e "$d" ]; then KEEP="$KEEP $d"; else echo "  aviso: $d nao existe, fica de fora"; fi ;;
    *)  echo "  aviso: ignorado (nao e caminho absoluto): $d" ;;
  esac
done
PATHS="${KEEP# }"
if [ -z "$PATHS" ]; then
  # Ultimo recurso, e so quando o backup remoto nao diz quais sao os caminhos dele. Configuravel
  # por FALLBACK_PATHS para o script servir uma maquina que nao seja esta.
  PATHS="${FALLBACK_PATHS:-$HOME/apps /var/lib/homelab-dashboard /var/backups/homelab /etc}"
  echo "sem caminhos validos do remoto: uso os de omissao ($PATHS)"
fi
EXCLUDE=$(grep -oP '(?<=--exclude-file=)[^ "]+' "$MAIN" 2>/dev/null | head -1 || true)
[ -n "$EXCLUDE" ] && [ ! -f "$EXCLUDE" ] && EXCLUDE=""
echo "caminhos: $PATHS"
[ -n "$EXCLUDE" ] && echo "exclusoes: $EXCLUDE"

# --- o script do backup local ----------------------------------------------------------------
cat > /usr/local/sbin/homelab-backup-local.sh <<EOS
#!/usr/bin/env bash
# Segunda cópia, no SSD ligado por USB. Instalado por setup-local-backup.sh.
set -euo pipefail
MOUNT=$MOUNT
REPO=$REPO
STATE=$STATE
PATHS=($(printf '%q ' $PATHS))
EXCLUDE=$EXCLUDE
export RESTIC_PASSWORD_FILE=$PWFILE
export HOME=/root XDG_CACHE_HOME=/root/.cache

write_state(){ # ok message
  mkdir -p "\$(dirname "\$STATE")"
  free=\$(df -B1 --output=avail "\$MOUNT" 2>/dev/null | tail -1 | tr -d ' ' || echo 0)
  total=\$(df -B1 --output=size "\$MOUNT" 2>/dev/null | tail -1 | tr -d ' ' || echo 0)
  snaps=\$(restic -r "\$REPO" snapshots --json 2>/dev/null | grep -c '"time"' || echo 0)
  cat > "\$STATE" <<EOJ
{"ok": \$1, "ts": \$(date +%s), "message": "\$2", "free_bytes": \${free:-0},
 "total_bytes": \${total:-0}, "snapshots": \${snaps:-0}, "mount": "\$MOUNT"}
EOJ
}

# Corrida recente? O botao "Run backup now" e o timer das 03:30 ja disparam esta copia a
# seguir a da nuvem; o timer proprio das 05:30 fica como rede de seguranca para quando a
# nuvem falha. FORCE=1 ignora esta guarda.
if [ "\${FORCE:-0}" != 1 ] && [ -f "\$STATE" ]; then
  last=\$(grep -oP '"ts":\s*\K[0-9]+' "\$STATE" 2>/dev/null | head -1 || echo 0)
  okp=\$(grep -oP '"ok":\s*\K(true|false)' "\$STATE" 2>/dev/null | head -1 || echo false)
  if [ "\$okp" = true ] && [ -n "\$last" ] && [ \$(( \$(date +%s) - last )) -lt 21600 ]; then
    echo "copia local ja feita ha menos de 6h, nada a fazer"
    exit 0
  fi
fi

# A GUARDA QUE INTERESSA: sem isto, um disco desligado faz o restic escrever no ponto de
# montagem vazio, ou seja no disco do sistema, e enche o NVMe sem ninguém dar por nada.
mountpoint -q "\$MOUNT" || { write_state false "disco de backup não está montado"; exit 1; }
[ -d "\$REPO" ] || { write_state false "repositório não encontrado no disco"; exit 1; }

restic -r "\$REPO" backup "\${PATHS[@]}" \${EXCLUDE:+--exclude-file="\$EXCLUDE"} --tag local
restic -r "\$REPO" forget --keep-daily 14 --keep-weekly 8 --keep-monthly 12 --prune
write_state true "ok"
EOS
# validar o que foi GERADO, nao so o gerador: foi isto que faltou a 2026-08-11, quando o
# script instalado tinha uma aspa a menos e so falhou na primeira corrida.
bash -n /usr/local/sbin/homelab-backup-local.sh || {
  rm -f /usr/local/sbin/homelab-backup-local.sh
  die "o script gerado tinha erro de sintaxe e NAO foi instalado (nada ficou meio feito)"
}
chmod 755 /usr/local/sbin/homelab-backup-local.sh

cat > /etc/systemd/system/homelab-backup-local.service <<EOF
[Unit]
Description=Homelab backup to the local USB SSD with restic
Wants=docker.service
After=docker.service $(systemd-escape -p --suffix=mount "$MOUNT")
RequiresMountsFor=$MOUNT

[Service]
Type=oneshot
TimeoutStartSec=3h
ExecStart=/usr/local/sbin/homelab-backup-local.sh
EOF

# 5h30: duas horas depois da nuvem, para os dois nunca competirem pelo disco nem pela rede
cat > /etc/systemd/system/homelab-backup-local.timer <<EOF
[Unit]
Description=Run the local USB backup daily

[Timer]
OnCalendar=*-*-* 05:30:00
Persistent=true
RandomizedDelaySec=20m

[Install]
WantedBy=timers.target
EOF

# verificação semanal da integridade: discos USB baratos mentem sobre o que escreveram
cat > /etc/systemd/system/homelab-backup-local-check.service <<EOF
[Unit]
Description=Weekly integrity check of the local backup repository
RequiresMountsFor=$MOUNT

[Service]
Type=oneshot
Environment=HOME=/root
Environment=RESTIC_PASSWORD_FILE=$PWFILE
ExecStart=/usr/bin/restic -r $REPO check --read-data-subset=5%
EOF
cat > /etc/systemd/system/homelab-backup-local-check.timer <<EOF
[Unit]
Description=Weekly local backup check

[Timer]
OnCalendar=Sun 07:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

# O botao "Run backup now" do dashboard dispara o servico da NUVEM. Para ele fazer as duas
# copias, a local corre a seguir, em sucesso.
# ATENCAO AO NOME: os drop-ins aplicam-se por ordem alfabetica e o no-gdrive.conf existente
# tem "OnSuccess=" (vazio, que LIMPA). Um ficheiro chamado also-local.conf viria antes e era
# anulado sem dar erro nenhum. Por isso zz-.
mkdir -p /etc/systemd/system/homelab-backup.service.d
cat > /etc/systemd/system/homelab-backup.service.d/zz-also-local.conf <<EOF
[Unit]
OnSuccess=homelab-backup-local.service
EOF

systemctl daemon-reload
systemctl enable --now homelab-backup-local.timer homelab-backup-local-check.timer
echo
echo "instalado. timers:"
systemctl list-timers 2>/dev/null | grep backup-local || true
echo
echo "encadeamento: $(systemctl show homelab-backup.service -p OnSuccess --value 2>/dev/null || echo '?')"
echo
echo "primeira cópia agora (pode demorar uns minutos):"
echo "  sudo systemctl start homelab-backup-local.service && journalctl -fu homelab-backup-local"
