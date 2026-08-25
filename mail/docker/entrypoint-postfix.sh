#!/bin/sh
# Renders mail/postfix/ into /etc/postfix and runs Postfix in the foreground.
set -eu

: "${MAIL_HOSTNAME:?MAIL_HOSTNAME is not set}"
: "${DB_HOST:?DB_HOST is not set}"
: "${DB_NAME:?DB_NAME is not set}"
: "${DB_USER:?DB_USER is not set}"
: "${DB_PASSWORD:?DB_PASSWORD is not set}"

src=/etc/stampyx/postfix

# Only the placeholders are substituted: main.cf also contains Postfix's own $myhostname,
# which a bare envsubst would blank out.
envsubst '${MAIL_HOSTNAME}' < "$src/main.cf" > /etc/postfix/main.cf

mkdir -p /etc/postfix/pgsql
for map in domains mailboxes senders aliases; do
    envsubst '${DB_HOST} ${DB_NAME} ${DB_USER} ${DB_PASSWORD}' \
        < "$src/pgsql/$map.cf" > "/etc/postfix/pgsql/$map.cf"
done

# The maps carry the database password and are read by unprivileged Postfix daemons.
chgrp postfix /etc/postfix/pgsql/*.cf
chmod 640 /etc/postfix/pgsql/*.cf

# master.cf ships as an append onto the distribution's file, so guard against a restart
# stacking a second copy of the submission and smtps services. The marker has to be our
# own: Debian's master.cf already carries a commented-out submission block, and matching
# on that silently skips the append.
marker='# --- appended by stampyx-infra ---'
if ! grep -qF "$marker" /etc/postfix/master.cf; then
    printf '\n%s\n' "$marker" >> /etc/postfix/master.cf
    cat "$src/master.cf.append" >> /etc/postfix/master.cf
fi

# smtpd runs chrooted, which is what the chroot column in master.cf asks for. The jail
# needs its own copy of the resolver and lookup files, or the SASL socket and the milter
# cannot be resolved by name and every connection dies with "no SASL authentication
# mechanisms" before it reaches a command.
chroot_etc=/var/spool/postfix/etc
mkdir -p "$chroot_etc"
for file in resolv.conf services hosts host.conf nsswitch.conf localtime; do
    if [ -f "/etc/$file" ]; then
        cp -fL "/etc/$file" "$chroot_etc/$file"
    fi
done

# There is no syslog daemon in the container; Postfix 3.4+ can write to stdout directly.
postconf -e 'maillog_file=/dev/stdout'

newaliases 2>/dev/null || true
postfix check || true

exec /usr/sbin/postfix start-fg
