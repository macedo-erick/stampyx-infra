#!/bin/sh
# Installs mail/dovecot/ into /etc/dovecot and runs Dovecot in the foreground.
set -eu

: "${DB_HOST:?DB_HOST is not set}"
: "${DB_NAME:?DB_NAME is not set}"
: "${DB_USER:?DB_USER is not set}"
: "${DB_PASSWORD:?DB_PASSWORD is not set}"
: "${API_INTERNAL_URL:?API_INTERNAL_URL is not set}"
: "${MAIL_INTERNAL_SECRET:?MAIL_INTERNAL_SECRET is not set}"
: "${MAIL_MASTER_USER:?MAIL_MASTER_USER is not set}"
: "${MAIL_MASTER_PASSWORD:?MAIL_MASTER_PASSWORD is not set}"

src=/etc/stampyx/dovecot

# The shipped dovecot.conf is self-contained; the distribution's conf.d is deliberately
# not included, so replacing the file wholesale is the whole configuration.
cp "$src/dovecot.conf" /etc/dovecot/dovecot.conf

envsubst '${DB_HOST} ${DB_NAME} ${DB_USER} ${DB_PASSWORD}' \
    < "$src/dovecot-sql.conf.ext" > /etc/dovecot/dovecot-sql.conf.ext
# Read by the auth process, which has already dropped to the dovecot user.
chown root:dovecot /etc/dovecot/dovecot-sql.conf.ext
chmod 640 /etc/dovecot/dovecot-sql.conf.ext

install -d -m 755 /usr/lib/dovecot/sieve-pipe
install -m 755 "$src/sieve-pipe/notify-mail-received.sh" \
    /usr/lib/dovecot/sieve-pipe/notify-mail-received.sh

# The Sieve pipe runs as the mail user with no inherited environment; this file is the only
# way the notify script learns where the API is and how to authenticate to it.
printf 'API_INTERNAL_URL=%s\nMAIL_INTERNAL_SECRET=%s\n' \
    "$API_INTERNAL_URL" "$MAIL_INTERNAL_SECRET" > /etc/dovecot/notify.env
chown root:vmail /etc/dovecot/notify.env
chmod 640 /etc/dovecot/notify.env

# The master user is what lets the API open any mailbox without holding its password.
# Hashed here rather than stored, so the passwd-file never carries the plaintext.
printf '%s:%s\n' "$MAIL_MASTER_USER" \
    "$(doveadm pw -s SHA512-CRYPT -p "$MAIL_MASTER_PASSWORD")" > /etc/dovecot/master-users
chown root:dovecot /etc/dovecot/master-users
chmod 640 /etc/dovecot/master-users

install -d -o vmail -g vmail -m 755 /data/vmail /data/sieve

exec dovecot -F
