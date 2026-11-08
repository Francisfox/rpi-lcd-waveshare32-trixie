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

# ---------- Caminhos ----------
CFG=/boot/firmware/config.txt
OVERLAY_FILE=/boot/firmware/overlays/waveshare32b.dtbo
XCONF=/etc/X11/xorg.conf.d/99-lcd.conf
LDM=/etc/lightdm/lightdm.conf
PANEL_DIR="$HOME/.config/lxpanel-pi/panels"
PANEL="$PANEL_DIR/panel"
PANEL_DEFAULT=/etc/xdg/lxpanel-pi/panels/panel
PCMAN_DIR="$HOME/.config/pcmanfm/default"
PCMAN_DEFAULT=/etc/xdg/pcmanfm/default/pcmanfm.conf
BACKUP_DIR="$HOME/backup-lcd"
STAMP="$(date +%Y%m%d-%H%M)"
OVERLAY_LINE="dtoverlay=waveshare32b,rotate=${ROTATE},speed=${SPEED}"

# ---------- Saída ----------
ok()   { printf '\e[32m[OK]\e[0m   %s\n' "$*"; }
info() { printf '\e[34m[..]\e[0m   %s\n' "$*"; }
warn() { printf '\e[33m[!!]\e[0m   %s\n' "$*"; }
fail() { printf '\e[31m[ERRO]\e[0m %s\n' "$*"; exit 1; }

# Arquivo de texto íntegro = sem bytes nulos
is_text() { [ "$(tr -dc '\000' < "$1" | wc -c)" -eq 0 ]; }

# ---------- Verificações iniciais ----------
preflight() {
  [ "$EUID" -ne 0 ] || fail "Rode sem sudo: ./lcd-setup.sh $1"
  [ -f "$CFG" ] || fail "Não encontrei $CFG. Este script é para Raspberry Pi OS Bookworm/Trixie."
  grep -q "trixie" /etc/os-release || warn "Sistema diferente do Trixie: testado apenas no Trixie."
  is_text "$CFG" || fail "$CFG está corrompido (bytes nulos). Restaure um backup antes de continuar."
  [ -f "$OVERLAY_FILE" ] || fail "Overlay waveshare32b não encontrado em /boot/firmware/overlays."
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
  sudo apt-get install -y xserver-xorg-video-fbdev xinput-calibrator
  ok "Pacotes instalados"
}

step_config() {
  info "Ajustando $CFG"
  sudo cp "$CFG" "$CFG.bak-$STAMP"

  grep -q '^dtparam=spi=on' "$CFG" || printf '\n[all]\ndtparam=spi=on\n' | sudo tee -a "$CFG" > /dev/null

  if grep -qE '^dtoverlay=waveshare32' "$CFG"; then
    sudo sed -i -E "s/^dtoverlay=waveshare32.*/${OVERLAY_LINE}/" "$CFG"
  else
    printf '\n[all]\n%s\n' "$OVERLAY_LINE" | sudo tee -a "$CFG" > /dev/null
  fi

  sudo sed -i 's/^dtoverlay=vc4-kms-v3d/#dtoverlay=vc4-kms-v3d/' "$CFG"
  sync

  is_text "$CFG" || fail "$CFG ficou corrompido após a gravação. Backup em $CFG.bak-$STAMP"
  ok "config.txt: overlay, SPI e KMS desativado (backup: $CFG.bak-$STAMP)"
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

# ---------- Comandos ----------
cmd_backup() {
  mkdir -p "$BACKUP_DIR"
  sudo cp "$CFG" "$BACKUP_DIR/config.txt"
  [ -f "$XCONF" ] && sudo cp "$XCONF" "$BACKUP_DIR/"
  sudo cp "$LDM" "$BACKUP_DIR/"
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
  step_config
  step_x11
  step_lightdm
  step_desktop
  cmd_backup
  echo
  ok "Instalação concluída. É preciso reiniciar para aplicar."
  read -rp "Reiniciar agora? [s/N] " r
  if [[ "$r" =~ ^[sS]$ ]]; then sudo reboot; else info "Quando quiser: sudo reboot"; fi
}

cmd_check() {
  echo "== Sistema";        grep PRETTY /etc/os-release; uname -r
  echo "== Energia";        vcgencmd get_throttled || true
  echo "== config.txt";     if is_text "$CFG"; then echo "íntegro (texto)"; else echo "CORROMPIDO"; fi
  grep -nE "waveshare|vc4-kms|spi=on" "$CFG" || true
  echo "== Framebuffers";   cat /proc/fb
  echo "== Driver do LCD";  sudo dmesg | grep -iE "graphics fb1|fbtft|ili9340" | tail -5 || true
  echo "== logind";         loginctl show-seat seat0 -p CanGraphical || true
  echo "== lightdm";        grep -n "logind-check-graphical" "$LDM" || echo "ajuste ausente"
  systemctl is-active lightdm || true
  echo "== Xorg (erros)";   grep -E "\(EE\)|fb1" /var/log/Xorg.0.log 2>/dev/null | tail -8 || true
  echo "== Barra";          grep -nE "iconsize|^\s*height=" "$PANEL" 2>/dev/null || echo "sem configuração de usuário"
  echo "== Fontes";         grep "Xft.dpi" "$HOME/.Xresources" 2>/dev/null || echo "DPI padrão"
  echo "== Ícones desktop"; grep "big_icon_size" "$PCMAN_DIR/pcmanfm.conf" 2>/dev/null || echo "padrão (48)"
  echo "== Cartão SD";      sudo dmesg | grep -iE "i/o error|fat-fs|ext4-fs error" | tail -5 || echo "sem erros"
  df -h / /boot/firmware
}

cmd_calibrate() {
  command -v xinput_calibrator > /dev/null || sudo apt-get install -y xinput-calibrator
  info "Toque nos alvos que aparecerem no LCD"
  DISPLAY=:0 xinput_calibrator
  info "Para manter a calibração, salve o bloco 'Section \"InputClass\"' acima em"
  info "/etc/X11/xorg.conf.d/99-calibration.conf"
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

  install    Aplica toda a configuração do LCD
  check      Diagnóstico completo
  backup     Salva as configurações em $BACKUP_DIR
  calibrate  Calibra o touch
  vnc        Acesso remoto à tela via VNC (túnel SSH)
  hdmi       Devolve o desktop ao HDMI

Parâmetros: ROTATE=$ROTATE SPEED=$SPEED DPI=$DPI ICONSIZE=$ICONSIZE
            PANEL_HEIGHT=$PANEL_HEIGHT DESKTOP_ICON=$DESKTOP_ICON
Exemplo:    SPEED=8000000 ./lcd-setup.sh install
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
