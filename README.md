# EncPanel — panou web pentru encoderele ffmpeg (S3)

Panou HTTPS cu utilizator și parolă pentru encoderele ffmpeg de pe serverul S3 (netstreaming.eu).

## Instalare

```bash
curl -fsSL https://raw.githubusercontent.com/maxvideostar/Encoder/main/install-encpanel.sh -o install-encpanel.sh
bash install-encpanel.sh
```

Scriptul întreabă domeniul (implicit `s3.netstreaming.eu`), portul (implicit `8443`), utilizatorul și parola.
Apoi panoul e la `https://DOMENIU:PORT/`.

Instalare fără întrebări:

```bash
DOMAIN=s3.netstreaming.eu PORT=8443 PANEL_USER=admin PANEL_PASS='parola-ta' bash install-encpanel.sh
```

Re-rularea scriptului actualizează panoul; la întrebarea de utilizator apasă Enter ca să păstrezi contul existent.

## HTTPS

- Port 80 liber → certificat Let's Encrypt (standalone), reînnoit automat.
- Port 80 ocupat de nginx → adaugă un mic server block pentru validare (cere confirmare, un singur reload nginx).
- Altfel → certificat self-signed. Portul 8443 funcționează și prin Cloudflare proxy (SSL „Full”).
- Necesită un record A în DNS (Cloudflare) pentru domeniu.

## Ce face

- Detectează automat serviciile systemd care rulează ffmpeg (inclusiv template-uri `nume@canal`) și scripturile `.sh` cu ffmpeg din `/root`, `/opt`, `/usr/local/bin`, `/home`, `/srv`, `/etc/encoders`, `/etc/ffmpeg`.
- Start / Stop / Restart, activare la boot, log live cu fps / bitrate / speed.
- Editare script, `.env` și unit systemd, cu backup automat (`/var/lib/encpanel/backups`) și verificare sintaxă bash.
- „Fă serviciu”: transformă un script simplu în serviciu systemd cu restart automat.
- CPU / RAM / rețea / temperatură / NVENC (Nvidia).
- „Alte procese ffmpeg”: orice ffmpeg pornit manual, din cron sau din scripturi din alte foldere, cu comanda completă. Butonul **„Salvează ca serviciu”** creează `enc-NUME.service` cu exact acea comandă (restart automat + pornire la boot), oprește procesul vechi (și scriptul-buclă care îl pornea) și pornește serviciul. Dacă procesul aparține deja unui serviciu nedetectat, butonul îl adaugă în panou.
- Securitate: parole hash PBKDF2, blocare 15 min după 5 încercări greșite, CSRF, cookie-uri Secure/HttpOnly, jurnal acțiuni.
- Repornirea panoului nu oprește encoderele.

## Comenzi

```
encpanel passwd     # schimbă utilizator / parolă
encpanel status     # starea serviciului
encpanel log        # log panou
encpanel audit      # ultimele acțiuni (cine, IP, ce)
encpanel url        # adresa panoului
encpanel uninstall  # dezinstalare
```

## Fișiere

| Cale | Ce e |
|---|---|
| `/opt/encpanel/` | aplicația (Flask + gunicorn) |
| `/etc/encpanel/config.json` | config, hash parolă, certificat |
| `/var/log/encpanel/` | loguri scripturi pornite din panou + audit |
| `/var/lib/encpanel/backups/` | backup-uri la fiecare editare |
