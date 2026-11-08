# LCD Waveshare 3.2" (V3) no Raspberry Pi — Raspberry Pi OS Trixie

Configuração testada e funcional do LCD SPI Waveshare/SpotPear 3.2" (revisão V3)
no Raspberry Pi OS Trixie, usando X11 + fbdev. Um único script aplica tudo.

> **Não use o script `LCD-show` da Waveshare no Trixie.** Ele grava no arquivo
> errado (`/boot/config.txt`) e deixa configurações que quebram o desktop.

## Hardware testado

| Item | Versão |
|---|---|
| Placa | Raspberry Pi 2 Model B V1.1 |
| Sistema | Raspberry Pi OS 13 (Trixie) 32-bit com desktop |
| Kernel | 6.18 |
| Tela | Waveshare / SpotPear 3.2inch RPi LCD — marcação **V3** (modelo B) |

---

## 1. Antes de começar: energia e cartão SD

- **Fonte de 5,1 V / 2,5 A ou mais** (de preferência a oficial), com cabo curto e grosso.
  Subtensão corrompe o cartão SD. Verifique com `vcgencmd get_throttled` — o ideal é `throttled=0x0`.
- **Cartão SD de marca** (SanDisk, Samsung ou Kingston, classe A1 ou superior).
- Evite periféricos de alto consumo (ex.: mouse com RGB) ligados direto no Pi 2.

## 2. Gravar o cartão SD

No **Raspberry Pi Imager**:

1. **Dispositivo:** Raspberry Pi 2.
2. **Sistema:** Raspberry Pi OS (32-bit), versão com desktop.
3. **Armazenamento:** o cartão SD.
4. Na etapa de **personalização**:
   - Nome do host, usuário e senha.
   - Fuso horário `America/Sao_Paulo` e teclado `br`.
   - **Ativar SSH** com autenticação por senha.
   - O Pi 2 **não tem Wi-Fi**: use cabo de rede ou adaptador USB.
5. Grave o cartão.

## 3. Montar a tela

Com o Raspberry **desligado**, encaixe o LCD nos **26 primeiros pinos** do GPIO,
com o **pino 1** da tela alinhado ao pino 1 da placa (canto do slot do cartão SD).
Uma fileira deslocada resulta em tela branca.

## 4. Primeiro acesso por SSH

Descubra o IP (pelo roteador, ou com monitor HDMI e `hostname -I`). No PowerShell:

```powershell
ssh USUARIO@IP_DO_RASPBERRY
```

## 5. Instalar a configuração do LCD

**Instalação rápida (um comando):**

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Francisfox/rpi-lcd-waveshare32-trixie/main/lcd-setup.sh) install
```

**Ou clonando o repositório** (recomendado, para ter os outros comandos à mão):

```bash
git clone https://github.com/Francisfox/rpi-lcd-waveshare32-trixie.git
cd rpi-lcd-waveshare32-trixie
chmod +x lcd-setup.sh
./lcd-setup.sh install
```
Rode **sem `sudo`**: o script pede a senha quando precisa. No final, ele oferece reiniciar.

Parâmetros opcionais:

```bash
ROTATE=90 SPEED=8000000 DPI=60 ./lcd-setup.sh install
```

| Variável | Padrão | Função |
|---|---|---|
| `ROTATE` | 270 | Rotação da tela (0, 90, 180, 270) |
| `SPEED` | 16000000 | Velocidade da SPI. Se a tela ficar branca, teste 8000000 |
| `DPI` | 72 | Tamanho das fontes (padrão do sistema: 96; 60 é o limite legível) |
| `ICONSIZE` | 16 | Ícones da barra superior |
| `PANEL_HEIGHT` | 20 | Altura da barra superior |
| `DESKTOP_ICON` | 24 | Ícones da área de trabalho (ex.: lixeira) |
| `SPLASH` | 1 | Tela de abertura em tela cheia no LCD e mensagens de boot ocultas (`0` desativa) |

## 6. Ajustes finais

```bash
./lcd-setup.sh calibrate   # calibrar o touch (tocar nos alvos no LCD)
./lcd-setup.sh backup      # salvar as configurações em ~/backup-lcd
```

- **Relógio cortado na barra:** remova itens pela interface — botão direito na barra →
  *Adicionar/Remover itens do painel*. Remover o navegador costuma bastar.
  Não edite os itens da barra por script: nos testes, isso fez a barra parar de iniciar.
- **Cursor do mouse:** o padrão (tema PiXtrix, 24 px) já é o menor tamanho efetivo.
  Configurar 16 px, inclusive com outro tema, não muda a aparência.

Copie o backup para o PC:

```powershell
scp -r USUARIO@IP_DO_RASPBERRY:~/backup-lcd .
```

## Todos os comandos

| Comando | Função |
|---|---|
| `./lcd-setup.sh install` | Aplica toda a configuração |
| `./lcd-setup.sh check` | Diagnóstico completo (inclui energia e cartão SD) |
| `./lcd-setup.sh backup` | Salva as configurações em `~/backup-lcd` |
| `./lcd-setup.sh calibrate` | Calibra o touch |
| `./lcd-setup.sh vnc` | Acesso remoto à tela via VNC (por túnel SSH) |
| `./lcd-setup.sh hdmi` | Devolve o desktop ao HDMI |

### Acesso remoto (VNC)

Depois de `./lcd-setup.sh vnc`, no Windows:

```powershell
ssh -L 5900:localhost:5900 USUARIO@IP_DO_RASPBERRY
```

Conecte um visualizador VNC (RealVNC Viewer, TightVNC) em `localhost:5900`.

---

## O que o script faz e por quê

| Ajuste | Motivo |
|---|---|
| `dtoverlay=waveshare32b,...,speed=16000000` em `/boot/firmware/config.txt` | No Trixie, o config fica em `/boot/firmware`. A V3 inicializa com o overlay `waveshare32b`; a 32 MHz, a tela fica branca |
| KMS desativado (`#dtoverlay=vc4-kms-v3d`) | Com KMS, o X falha com *"Cannot run in framebuffer mode"* |
| X11 em vez de Wayland | O Wayland não desenha em tela SPI |
| `/etc/X11/xorg.conf.d/99-lcd.conf` | Força o X a usar o `/dev/fb1` (LCD) |
| Remoção do `99-fbturbo.conf` | Sobra do LCD-show; driver inexistente no Trixie |
| `logind-check-graphical=false` no lightdm | Sem KMS, o logind marca `CanGraphical=no` e o lightdm não inicia o X |
| Barra 16 px, `Xft.dpi: 72`, ícones da área de trabalho 24 px | Proporção adequada para 320×240 |
| Serviço `lcd-splash` (fbi no `/dev/fb1`) | Sem KMS, o Plymouth não aparece; o serviço recria a tela de abertura no LCD |
| `quiet loglevel=3 systemd.show_status=false vt.global_cursor_default=0 logo.nologo` no `cmdline.txt` | Oculta o texto de inicialização, que sobrepunha a imagem |

## Solução de problemas

| Sintoma | Causa provável | Ação |
|---|---|---|
| Tela branca | Overlay não carregou ou velocidade alta | `./lcd-setup.sh check`; testar `SPEED=8000000` |
| Tela branca após `apt upgrade` | `config.txt` corrompido ou substituído | `./lcd-setup.sh check` e restaurar de `~/backup-lcd` |
| Logo aparece e depois só um cursor | X não subiu | `./lcd-setup.sh check` (ver lightdm e Xorg) |
| Barra sumiu | Configuração da barra inválida | `mv ~/.config/lxpanel-pi ~/lxpanel-pi.old` e `sudo systemctl restart lightdm` |
| Erro no `apt update` (*MergeList*) | Lista de pacotes corrompida | `sudo rm -rf /var/lib/apt/lists/* && sudo apt update` |
| `throttled` diferente de `0x0` | Fonte ou cabo insuficiente | Trocar a fonte; usar hub com fonte própria para periféricos |
| Dispositivo USB não aparece no `lsblk` | Falta de energia | Mesma ação acima |
| Texto aparece por cima da tela de abertura | Mensagens de boot no mesmo terminal | Conferir `cmdline.txt` com `./lcd-setup.sh check` |
| Quer ver as mensagens de boot | — | `SPLASH=0 ./lcd-setup.sh install` e restaurar `cmdline.txt.bak-*` |
**Antes de qualquer `apt upgrade`, rode `./lcd-setup.sh backup`.**

## Sobre boot por USB (Pi 2 v1.1)

O Pi 2 v1.1 não inicia direto pelo USB. É possível manter só a partição de boot no
cartão SD e o sistema num SSD/pendrive, mas isso exige energia estável e não foi
testado neste projeto.
