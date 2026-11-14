#!/usr/bin/env bash
# lcd-setup.sh — LCD Waveshare 3.2" (V3) no Raspberry Pi OS Trixie (X11 + fbdev)
# Uso: ./lcd-setup.sh {install|check|backup|calibrate|vnc|hdmi}
set -euo pipefail

# ---------- Parâmetros (podem ser sobrescritos por variável de ambiente) ----------
ROTATE="${ROTATE:-270}"
SPEED="${SPEED:-16000000}"
DPI="${DPI:-72}"
ICONSIZE="${ICONSIZE:-16}"
PANEL_HEIGHT="${PANEL_HEIGHT:-20}"
DESKTOP_ICON="${DESKTOP_ICON:-24}"
SPLASH="${SPLASH:-1}"
TOUCH="${TOUCH:-1}"                                   # 0 = não configura o touch
TOUCH_INVERT="${TOUCH_INVERT:-invx}"                  # invx | invy | invx,invy | none
CALIB_MATRIX="${CALIB_MATRIX:-1.1940 0 -0.0821 0 1.2329 -0.1807 0 0 1}"
DESKTOP_PKG="${DESKTOP_PKG:-rpd-x-core}"              # instalado só se o desktop faltar (imagem Lite)

# ---------- Caminhos ----------
CFG=/boot/firmware/config.txt
CMDLINE=/boot/firmware/cmdline.txt
OVERLAY_DIR=/boot/firmware/overlays
XCONF=/etc/X11/xorg.conf.d/99-lcd.conf
CALIB=/etc/X11/xorg.conf.d/99-calibration.conf
LDM=/etc/lightdm/lightdm.conf
PANEL_DIR="$HOME/.config/lxpanel-pi/panels"
PANEL="$PANEL_DIR/panel"
PANEL_DEFAULT=/etc/xdg/lxpanel-pi/panels/panel
PCMAN_DIR="$HOME/.config/pcmanfm/default"
PCMAN_DEFAULT=/etc/xdg/pcmanfm/default/pcmanfm.conf
SPLASH_IMG=/usr/share/plymouth/themes/pix/splash.png
SPLASH_SVC=/etc/systemd/system/lcd-splash.service
BACKUP_DIR="$HOME/backup-lcd"
STAMP="$(date +%Y%m%d-%H%M)"
TOUCH_NAME="ADS7846 Touchscreen"

# Definidos em detect_overlay()
OVERLAY_MODE=""
LCD_LINE=""
TOUCH_LINE=""

# ---------- Saída ----------
ok()   { printf '\e[32m[OK]\e[0m   %s\n' "$*"; }
info() { printf '\e[34m[..]\e[0m   %s\n' "$*"; }
warn() { printf '\e[33m[!!]\e[0m   %s\n' "$*"; }
fail() { printf '\e[31m[ERRO]\e[0m %s\n' "$*"; exit 1; }

# Arquivo de texto íntegro = sem bytes nulos
is_text() { [ "$(tr -dc '\000' < "$1" | wc -c)" -eq 0 ]; }

# ---------- Overlay do LCD ----------
# Kernels antigos trazem o overlay dedicado waveshare32b.dtbo (já inclui o touch).
# Nos kernels atuais ele foi removido: o mesmo preset virou parâmetro do overlay
# genérico fbtft, e o touch passa a ser um overlay separado (ads7846).
detect_overlay() {
  if [ -f "$OVERLAY_DIR/waveshare32b.dtbo" ]; then
    OVERLAY_MODE=legacy
    LCD_LINE="dtoverlay=waveshare32b,rotate=${ROTATE},speed=${SPEED}"
    TOUCH_LINE=""
  elif [ -f "$OVERLAY_DIR/fbtft.dtbo" ]; then
    OVERLAY_MODE=fbtft
    LCD_LINE="dtoverlay=fbtft,spi0-0,waveshare32b,rotate=${ROTATE},speed=${SPEED},reset_pin=27,dc_pin=22"
    local inv=""
    [ "$TOUCH_INVERT" = "none" ] || inv=",${TOUCH_INVERT}"
    TOUCH_LINE="dtoverlay=ads7846,cs=1,penirq=17,swapxy,pmax=255,xohms=60${inv}"
    [ "$TOUCH" = "1" ] || TOUCH_LINE=""
  else
    fail "Nenhum overlay do LCD encontrado (waveshare32b.dtbo ou fbtft.dtbo) em $OVERLAY_DIR."
  fi
}

# ---------- Verificações iniciais ----------
preflight() {
  [ "$EUID" -ne 0 ] || fail "Rode sem sudo: ./lcd-setup.sh $1"
  [ -f "$CFG" ] || fail "Não encontrei $CFG. Este script é para Raspberry Pi OS Bookworm/Trixie."
  grep -q "trixie" /etc/os-release || warn "Sistema diferente do Trixie: testado apenas no Trixie."
  is_text "$CFG" || fail "$CFG está corrompido (bytes nulos). Restaure um backup antes de continuar."
  is_text "$CMDLINE" || fail "$CMDLINE está corrompido (bytes nulos). Restaure um backup antes de continuar."
  detect_overlay
  if [ "$OVERLAY_MODE" = "fbtft" ]; then
    ok "Overlay: fbtft com preset waveshare32b (kernel $(uname -r))"
    if [ "$TOUCH" = "1" ] && [ "$ROTATE" != "270" ]; then
      warn "Direção do touch validada só com ROTATE=270. Se ficar invertido, ajuste TOUCH_INVERT."
    fi
  else
    ok "Overlay: waveshare32b dedicado (kernel $(uname -r))"
  fi
  local t; t=$(vcgencmd get_throttled 2>/dev/null | cut -d= -f2 || echo "?")
  [ "$t" = "0x0" ] || warn "Energia: throttled=$t. Fonte insuficiente pode corromper o cartão SD."
  ok "Verificações iniciais"
}

# ---------- Etapas da instalação ----------
step_packages() {
  info "Atualizando lista de pacotes"
  if ! sudo apt-get update; then
    warn "Lista do apt corrompida — limpando e tentando de novo"
    sudo rm -rf /var/lib/apt/lists/*
    sudo apt-get update
  fi
  # Conclui instalações interrompidas antes de instalar qualquer coisa
  sudo dpkg --configure -a || true
  sudo apt-get install -y xserver-xorg-video-fbdev xinput-calibrator xinput fbi
  ok "Pacotes instalados"
}

# Imagem Lite não tem desktop: instala o básico (barra, pcmanfm, lightdm)
step_desktop_pkgs() {
  if [ -f "$LDM" ] && [ -f "$PANEL_DEFAULT" ] && [ -f "$PCMAN_DEFAULT" ]; then
    ok "Desktop já instalado"
    return 0
  fi
  warn "Desktop não encontrado (imagem Lite?). Instalando $DESKTOP_PKG — no Pi 2 leva de 30 a 60 min"
  if ! sudo apt-get install -y "$DESKTOP_PKG" lightdm; then
    warn "Dependências pendentes — rodando apt --fix-broken install"
    sudo apt-get --fix-broken install -y
    sudo apt-get install -y "$DESKTOP_PKG" lightdm
  fi
  [ -f "$LDM" ] || fail "lightdm não ficou instalado. Rode 'sudo apt --fix-broken install' e repita o install."
  sudo raspi-config nonint do_boot_behaviour B4
  ok "Desktop instalado e configurado para abrir no boot"
}

step_config() {
  info "Ajustando $CFG"
  sudo cp "$CFG" "$CFG.bak-$STAMP"

  grep -q '^dtparam=spi=on' "$CFG" || printf '\n[all]\ndtparam=spi=on\n' | sudo tee -a "$CFG" > /dev/null

  # Remove linhas antigas do LCD/touch e grava as atuais (rodar de novo não duplica)
  sudo sed -i -E '/^dtoverlay=(waveshare32|fbtft|ads7846)/d' "$CFG"
  {
    printf '\n[all]\n%s\n' "$LCD_LINE"
    [ -z "$TOUCH_LINE" ] || printf '%s\n' "$TOUCH_LINE"
  } | sudo tee -a "$CFG" > /dev/null

  sudo sed -i 's/^dtoverlay=vc4-kms-v3d/#dtoverlay=vc4-kms-v3d/' "$CFG"
  sync

  is_text "$CFG" || fail "$CFG ficou corrompido após a gravação. Backup em $CFG.bak-$STAMP"
  ok "config.txt: overlay ($OVERLAY_MODE), SPI e KMS desativado (backup: $CFG.bak-$STAMP)"
}

step_x11() {
  info "Configurando X11 no LCD"
  sudo raspi-config nonint do_wayland W1
  mkdir -p "$BACKUP_DIR"
  for f in /usr/share/X11/xorg.conf.d/99-fbturbo.conf /etc/X11/xorg.conf.d/99-fbturbo.conf; do
    if [ -f "$f" ]; then sudo mv "$f" "$BACKUP_DIR/"; warn "Removido $f (sobra do LCD-show)"; fi
  done
  sudo mkdir -p /etc/X11/xorg.conf.d
  sudo tee "$XCONF" > /dev/null <<'EOF'
Section "Device"
    Identifier "LCD"
    Driver "fbdev"
    Option "fbdev" "/dev/fb1"
EndSection

Section "Screen"
    Identifier "LCDScreen"
    Device "LCD"
EndSection

Section "ServerLayout"
    Identifier "Layout"
    Screen "LCDScreen"
EndSection
EOF
  ok "X11 + fbdev apontando para /dev/fb1"
}

step_lightdm() {
  info "Ajustando lightdm"
  sudo cp "$LDM" "$LDM.bak-$STAMP"
  sudo sed -i '/^logind-check-graphical=/d' "$LDM"
  if grep -q '^\[LightDM\]' "$LDM"; then
    sudo sed -i '0,/^\[LightDM\]/s//[LightDM]\nlogind-check-graphical=false/' "$LDM"
  else
    printf '\n[LightDM]\nlogind-check-graphical=false\n' | sudo tee -a "$LDM" > /dev/null
  fi
  [ "$(grep -c '^logind-check-graphical=false' "$LDM")" -eq 1 ] || fail "lightdm.conf não ficou como esperado"
  ok "lightdm inicia o X sem KMS"
}

step_desktop() {
  info "Ajustando barra, fontes e ícones"

  # Barra superior
  mkdir -p "$PANEL_DIR"
  if [ ! -f "$PANEL" ] && [ -f "$PANEL_DEFAULT" ]; then cp "$PANEL_DEFAULT" "$PANEL"; fi
  if [ -f "$PANEL" ]; then
    sed -i -E "s/^(\s*)iconsize=.*/\1iconsize=${ICONSIZE}/; s/^(\s*)height=.*/\1height=${PANEL_HEIGHT}/" "$PANEL"
    ok "Barra: ícones ${ICONSIZE} px, altura ${PANEL_HEIGHT} px"
  else
    warn "Configuração da barra não encontrada — rode o install de novo após o primeiro login"
  fi

  # Fontes
  touch "$HOME/.Xresources"
  sed -i '/^Xft.dpi:/d' "$HOME/.Xresources"
  echo "Xft.dpi: ${DPI}" >> "$HOME/.Xresources"
  ok "Fontes: Xft.dpi ${DPI}"

  # Ícones da área de trabalho (lixeira etc.)
  mkdir -p "$PCMAN_DIR"
  if [ ! -f "$PCMAN_DIR/pcmanfm.conf" ] && [ -f "$PCMAN_DEFAULT" ]; then cp "$PCMAN_DEFAULT" "$PCMAN_DIR/"; fi
  if [ -f "$PCMAN_DIR/pcmanfm.conf" ]; then
    if grep -q '^big_icon_size=' "$PCMAN_DIR/pcmanfm.conf"; then
      sed -i "s/^big_icon_size=.*/big_icon_size=${DESKTOP_ICON}/" "$PCMAN_DIR/pcmanfm.conf"
    else
      sed -i "/^\[ui\]/a big_icon_size=${DESKTOP_ICON}" "$PCMAN_DIR/pcmanfm.conf"
    fi
    ok "Ícones da área de trabalho: ${DESKTOP_ICON} px"
  else
    warn "Configuração do pcmanfm não encontrada — ícones da área de trabalho não ajustados"
  fi
}

# Calibração inicial do touch (driver libinput). Não sobrescreve calibração já feita.
step_touch() {
  if [ "$OVERLAY_MODE" != "fbtft" ] || [ "$TOUCH" != "1" ]; then return 0; fi
  if [ -f "$CALIB" ]; then
    ok "Touch: calibração existente mantida ($CALIB)"
    return 0
  fi
  write_calibration "$CALIB_MATRIX"
  ok "Touch: calibração padrão gravada (refinar com ./lcd-setup.sh calibrate)"
}

write_calibration() {
  sudo mkdir -p /etc/X11/xorg.conf.d
  sudo tee "$CALIB" > /dev/null <<EOF
Section "InputClass"
        Identifier      "calibration"
        MatchProduct    "${TOUCH_NAME}"
        Option  "CalibrationMatrix"  "$1"
EndSection
EOF
}

step_splash() {
  if [ "$SPLASH" != "1" ]; then info "Tela de abertura desativada (SPLASH=0)"; return 0; fi
  info "Configurando tela de abertura no LCD"
  if [ ! -f "$SPLASH_IMG" ]; then
    warn "Imagem $SPLASH_IMG não encontrada — tela de abertura não configurada"
    return 0
  fi

  # Serviço que mostra a imagem no LCD assim que o driver carrega
  sudo tee "$SPLASH_SVC" > /dev/null <<'EOF'
[Unit]
Description=Imagem de abertura no LCD
DefaultDependencies=no
After=systemd-modules-load.service
Before=lightdm.service

[Service]
Type=simple
RemainAfterExit=yes
ExecStartPre=/bin/sh -c 'for i in $(seq 1 120); do [ -e /dev/fb1 ] && exit 0; sleep 0.5; done; exit 1'
ExecStart=/usr/bin/fbi -d /dev/fb1 -T 2 --noverbose -a /usr/share/plymouth/themes/pix/splash.png
StandardInput=tty
TTYPath=/dev/tty2

[Install]
WantedBy=sysinit.target
EOF

  # Encerra a imagem quando o desktop abre
  sudo mkdir -p /etc/systemd/system/lightdm.service.d
  sudo tee /etc/systemd/system/lightdm.service.d/stop-splash.conf > /dev/null <<'EOF'
[Service]
ExecStartPre=-/usr/bin/pkill -x fbi
EOF
  sudo systemctl daemon-reload
  sudo systemctl enable lcd-splash.service

  # Oculta as mensagens de inicialização
  sudo cp "$CMDLINE" "$CMDLINE.bak-$STAMP"
  for p in quiet loglevel=3 systemd.show_status=false vt.global_cursor_default=0 logo.nologo; do
    grep -qw -- "$p" "$CMDLINE" || sudo sed -i "s/\$/ $p/" "$CMDLINE"
  done
  [ "$(wc -l < "$CMDLINE")" -le 1 ] || fail "cmdline.txt ficou com mais de uma linha. Backup em $CMDLINE.bak-$STAMP"
  sync
  ok "Tela de abertura ativa e mensagens de boot ocultas (backup: $CMDLINE.bak-$STAMP)"
}

# ---------- Comandos ----------
cmd_backup() {
  mkdir -p "$BACKUP_DIR"
  sudo cp "$CFG" "$BACKUP_DIR/config.txt"
  sudo cp "$CMDLINE" "$BACKUP_DIR/cmdline.txt"
  [ -f "$XCONF" ] && sudo cp "$XCONF" "$BACKUP_DIR/"
  [ -f "$CALIB" ] && sudo cp "$CALIB" "$BACKUP_DIR/"
  [ -f "$SPLASH_SVC" ] && sudo cp "$SPLASH_SVC" "$BACKUP_DIR/"
  [ -f "$LDM" ] && sudo cp "$LDM" "$BACKUP_DIR/"
  [ -d "$HOME/.config/lxpanel-pi" ] && cp -r "$HOME/.config/lxpanel-pi" "$BACKUP_DIR/"
  [ -d "$HOME/.config/pcmanfm" ] && cp -r "$HOME/.config/pcmanfm" "$BACKUP_DIR/"
  [ -f "$HOME/.Xresources" ] && cp "$HOME/.Xresources" "$BACKUP_DIR/Xresources"
  sudo chown -R "$USER:$USER" "$BACKUP_DIR"
  ok "Backup em $BACKUP_DIR"
  ls -l "$BACKUP_DIR"
}

cmd_install() {
  preflight install
  step_packages
  step_desktop_pkgs
  step_config
  step_x11
  step_lightdm
  step_desktop
  step_touch
  step_splash
  cmd_backup
  echo
  ok "Instalação concluída. É preciso reiniciar para aplicar."
  read -rp "Reiniciar agora? [s/N] " r
  if [[ "$r" =~ ^[sS]$ ]]; then sudo reboot; else info "Quando quiser: sudo reboot"; fi
}

cmd_check() {
  echo "== Sistema";            grep PRETTY /etc/os-release; uname -r
  echo "== Energia";            vcgencmd get_throttled || true
  echo "== config.txt";         if is_text "$CFG"; then echo "íntegro (texto)"; else echo "CORROMPIDO"; fi
  grep -nE "waveshare|fbtft|ads7846|vc4-kms|spi=on" "$CFG" || true
  echo "== Overlays";           ls "$OVERLAY_DIR"/waveshare32b.dtbo "$OVERLAY_DIR"/fbtft.dtbo 2>/dev/null || echo "nenhum overlay do LCD"
  echo "== cmdline.txt";        cat "$CMDLINE"
  echo "== Framebuffers";       cat /proc/fb
  echo "== Driver do LCD";      sudo dmesg | grep -iE "graphics fb1|fbtft|ili9340" | tail -5 || true
  echo "== Touch";              grep -q "$TOUCH_NAME" /proc/bus/input/devices && echo "$TOUCH_NAME detectado" || echo "touch não detectado"
  DISPLAY=:0 xinput list-props "$TOUCH_NAME" 2>/dev/null | grep "Calibration Matrix (" || true
  echo "== logind";             loginctl show-seat seat0 -p CanGraphical || true
  echo "== lightdm";            grep -n "logind-check-graphical" "$LDM" 2>/dev/null || echo "ajuste ausente ou lightdm não instalado"
  systemctl is-active lightdm || true
  echo "== Xorg (erros)";       grep -E "\(EE\)|fb1" /var/log/Xorg.0.log 2>/dev/null | tail -8 || true
  echo "== Barra";              grep -nE "iconsize|^\s*height=" "$PANEL" 2>/dev/null || echo "sem configuração de usuário"
  echo "== Fontes";             grep "Xft.dpi" "$HOME/.Xresources" 2>/dev/null || echo "DPI padrão"
  echo "== Ícones desktop";     grep "big_icon_size" "$PCMAN_DIR/pcmanfm.conf" 2>/dev/null || echo "padrão (48)"
  echo "== Tela de abertura";   systemctl is-enabled lcd-splash.service 2>/dev/null || echo "não configurada"
  echo "== Cartão SD";          sudo dmesg | grep -iE "i/o error|fat-fs|ext4-fs error" | tail -5 || echo "sem erros"
  df -h / /boot/firmware
}

# Calibra o touch e grava o resultado como matriz do libinput (permanente)
cmd_calibrate() {
  command -v xinput_calibrator > /dev/null || sudo apt-get install -y xinput-calibrator
  command -v xinput > /dev/null || sudo apt-get install -y xinput
  export DISPLAY=:0
  xinput list --name-only 2>/dev/null | grep -qx "$TOUCH_NAME" \
    || fail "Touch '$TOUCH_NAME' não encontrado no X. O desktop está aberto no LCD?"

  # Zera a calibração atual para medir os valores brutos
  xinput set-prop "$TOUCH_NAME" "libinput Calibration Matrix" 1 0 0 0 1 0 0 0 1 2>/dev/null \
    || warn "Não consegui zerar a matriz atual — o resultado pode sair deslocado"

  info "Toque nos alvos que aparecerem no LCD"
  local out; out=$(xinput_calibrator 2>&1) || true
  printf '%s\n' "$out"

  val() { printf '%s\n' "$out" | sed -n "s/.*\"$1\"[[:space:]]*\"\(-\{0,1\}[0-9]*\)\".*/\1/p" | head -1; }
  local minx maxx miny maxy rx0 rx1 ry0 ry1
  minx=$(val MinX); maxx=$(val MaxX); miny=$(val MinY); maxy=$(val MaxY)
  rx0=$(printf '%s\n' "$out" | sed -n 's/.*min_x=\([0-9]*\).*/\1/p' | head -1)
  rx1=$(printf '%s\n' "$out" | sed -n 's/.*max_x=\([0-9]*\).*/\1/p' | head -1)
  ry0=$(printf '%s\n' "$out" | sed -n 's/.*min_y=\([0-9]*\).*/\1/p' | head -1)
  ry1=$(printf '%s\n' "$out" | sed -n 's/.*max_y=\([0-9]*\).*/\1/p' | head -1)
  for v in "$minx" "$maxx" "$miny" "$maxy" "$rx0" "$rx1" "$ry0" "$ry1"; do
    [ -n "$v" ] || fail "Não consegui ler o resultado da calibração. Rode de novo e toque nos 4 alvos."
  done
  [ "$minx" != "$maxx" ] && [ "$miny" != "$maxy" ] || fail "Valores de calibração inválidos. Rode de novo."

  # x' = x*(faixa)/(MaxX-MinX) + (início - MinX)/(MaxX-MinX); idem para y
  local matrix
  matrix=$(awk -v a="$minx" -v b="$maxx" -v c="$miny" -v d="$maxy" \
               -v r0="$rx0" -v r1="$rx1" -v s0="$ry0" -v s1="$ry1" 'BEGIN {
    dx = b - a; dy = d - c
    printf "%.4f 0 %.4f 0 %.4f %.4f 0 0 1", (r1 - r0) / dx, (r0 - a) / dx, (s1 - s0) / dy, (s0 - c) / dy
  }')

  # shellcheck disable=SC2086
  xinput set-prop "$TOUCH_NAME" "libinput Calibration Matrix" $matrix 2>/dev/null || true
  write_calibration "$matrix"
  ok "Calibração aplicada e gravada em $CALIB"
  info "Matriz: $matrix"
  if printf '%s\n' "$out" | grep -qE '"SwapXY"[[:space:]]*"1"'; then
    warn "O calibrador indicou eixos trocados. Ajuste TOUCH_INVERT e rode o install de novo."
  fi
}

cmd_vnc() {
  sudo apt-get install -y x11vnc
  [ -f "$HOME/.vnc/passwd" ] || x11vnc -storepasswd
  mkdir -p "$HOME/.config/autostart"
  cat > "$HOME/.config/autostart/x11vnc.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=x11vnc
Exec=x11vnc -display :0 -localhost -rfbauth $HOME/.vnc/passwd -forever -bg
EOF
  x11vnc -display :0 -auth guess -localhost -rfbauth "$HOME/.vnc/passwd" -forever -bg || true
  ok "VNC ativo (apenas via túnel SSH)"
  info "No Windows: ssh -L 5900:localhost:5900 $USER@$(hostname -I | awk '{print $1}')"
  info "Depois conecte o visualizador VNC em localhost:5900"
}

cmd_hdmi() {
  mkdir -p "$BACKUP_DIR"
  sudo cp "$CFG" "$CFG.bak-$STAMP"
  sudo sed -i 's/^#dtoverlay=vc4-kms-v3d/dtoverlay=vc4-kms-v3d/' "$CFG"
  if [ -f "$XCONF" ]; then sudo mv "$XCONF" "$BACKUP_DIR/"; fi
  sync
  ok "Desktop devolvido ao HDMI. Reinicie: sudo reboot"
  info "Para voltar ao LCD: ./lcd-setup.sh install"
}

usage() {
  cat <<EOF
Uso: ./lcd-setup.sh <comando>

  install    Aplica toda a configuração do LCD (e instala o desktop se faltar)
  check      Diagnóstico completo
  backup     Salva as configurações em $BACKUP_DIR
  calibrate  Calibra o touch e grava a calibração
  vnc        Acesso remoto à tela via VNC (túnel SSH)
  hdmi       Devolve o desktop ao HDMI

Parâmetros: ROTATE=$ROTATE SPEED=$SPEED DPI=$DPI ICONSIZE=$ICONSIZE
            PANEL_HEIGHT=$PANEL_HEIGHT DESKTOP_ICON=$DESKTOP_ICON SPLASH=$SPLASH
            TOUCH=$TOUCH TOUCH_INVERT=$TOUCH_INVERT DESKTOP_PKG=$DESKTOP_PKG
            CALIB_MATRIX="$CALIB_MATRIX"
Exemplo:    SPLASH=0 ./lcd-setup.sh install
EOF
}

case "${1:-}" in
  install)   cmd_install ;;
  check)     cmd_check ;;
  backup)    cmd_backup ;;
  calibrate) cmd_calibrate ;;
  vnc)       cmd_vnc ;;
  hdmi)      cmd_hdmi ;;
  *)         usage ;;
esac
