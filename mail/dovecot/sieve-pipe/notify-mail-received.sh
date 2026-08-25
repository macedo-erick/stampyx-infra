#!/bin/sh
# Called by the Sieve `pipe :copy` on every delivery that nothing filed away. Reads the
# message on stdin, pulls out the headers the panel needs, and hands them to the API.
#
# :copy means Sieve does not wait on the exit status, so a failure here delays no delivery.

set -eu

# Dovecot's sieve_extprograms execs with a cleared environment, so nothing the container
# was started with reaches this script. The entrypoint drops the two values it needs here.
if [ -f /etc/dovecot/notify.env ]; then
    . /etc/dovecot/notify.env
fi

header() {
    sed -n "/^$1:/I{s/^$1:[[:space:]]*//Ip;q;}"
}

# The Sieve script passes the folder it filed the message into; without it every
# report claimed INBOX, wherever the message actually went.
folder=${1:-INBOX}

message=$(cat)

# Dovecot's sieve_extprograms clears the environment, so $USER is empty here and the
# payload used to go out with an empty mailbox - which the API rejected with a 400 that
# nothing ever saw. The delivered message carries the recipient itself.
mailbox=$(printf '%s' "$message" | header 'Delivered-To')
if [ -z "$mailbox" ]; then
    mailbox=$(printf '%s' "$message" | header 'X-Original-To')
fi
if [ -z "$mailbox" ]; then
    mailbox=${USER:-}
fi

message_id=$(printf '%s' "$message" | header 'Message-ID')
sender=$(printf '%s' "$message" | header 'From' | sed -n 's/.*<\(.*\)>.*/\1/p;t;p' | head -1)
subject=$(printf '%s' "$message" | header 'Subject')
spam_score=$(printf '%s' "$message" | header 'X-Spam-Score')
in_reply_to=$(printf '%s' "$message" | header 'In-Reply-To')

escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\r\n'
}

extra=''
if [ -n "$spam_score" ]; then
    extra=$(printf ',"spamScore":%s' "${spam_score%%.*}")
fi

if [ -z "$mailbox" ]; then
    echo "stampyx-notify: no recipient on the message, nothing reported" >&2
    exit 0
fi

# Never fails the delivery, but no longer fails silently either: dovecot's log_path is
# stderr, so a rejected report shows up in the mail log instead of vanishing.
response=$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' \
    -X POST "${API_INTERNAL_URL}/internal/mail/received" \
    -H 'Content-Type: application/json' \
    -H "X-Stampyx-Internal: ${MAIL_INTERNAL_SECRET}" \
    -d "{\"mailbox\":\"$(escape "$mailbox")\",\"messageId\":\"$(escape "$message_id")\",\"sender\":\"$(escape "$sender")\",\"subject\":\"$(escape "$subject")\",\"folder\":\"$(escape "$folder")\",\"inReplyTo\":\"$(escape "$in_reply_to")\"${extra}}" \
    2>&1) || response='000'

case "$response" in
    2*) ;;
    *) echo "stampyx-notify: API answered ${response} for ${mailbox}" >&2 ;;
esac
