#!/bin/sh
# Local only. Production mounts the Let's Encrypt files at this exact path; this writes a
# self-signed stand-in there so main.cf and dovecot.conf need no local variant.
#
# The SANs cover the compose service names as well as the hostname, because the API reaches
# the containers as postfix:587 and dovecot:143 and validates the certificate against that.
set -eu

host=${MAIL_HOSTNAME:-mail.stampyx.com}
dir=/etc/letsencrypt/live/$host

if [ -f "$dir/fullchain.pem" ] && [ -f "$dir/privkey.pem" ]; then
    echo "dev-cert: $dir already exists; leaving it alone"
    exit 0
fi

mkdir -p "$dir"

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -subj "/CN=$host" \
    -addext "subjectAltName=DNS:$host,DNS:postfix,DNS:dovecot,DNS:localhost,IP:127.0.0.1" \
    -addext 'basicConstraints=critical,CA:TRUE' \
    -addext 'keyUsage=digitalSignature,keyEncipherment,keyCertSign' \
    -keyout "$dir/privkey.pem" -out "$dir/fullchain.pem" 2>/dev/null

# Postfix reads the key as the unprivileged smtpd user, and this is a throwaway dev key.
chmod 644 "$dir/fullchain.pem" "$dir/privkey.pem"

echo "dev-cert: wrote a self-signed certificate for $host"
