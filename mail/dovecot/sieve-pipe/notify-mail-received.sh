#!/bin/sh
# Called by the Sieve `pipe :copy` on every unfiled delivery: reads the message on stdin and
# hands the panel's headers to the API. :copy ignores the exit status, so a failure delays nothing.

set -eu

# sieve_extprograms execs with a cleared environment, so the entrypoint drops these two here.
if [ -f /etc/dovecot/notify.env ]; then
    . /etc/dovecot/notify.env
fi

header() {
    sed -n "/^$1:/I{s/^$1:[[:space:]]*//Ip;q;}"
}

# Passed by the Sieve script; without it every report claimed INBOX wherever the message went.
folder=${1:-INBOX}

message=$(cat)

# $USER is empty under the cleared environment, and the payload used to go out with an empty
# mailbox for the API to reject with an unseen 400. The delivered message carries the recipient.
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

# Never fails the delivery, but no longer silently: log_path is stderr, so a rejected report is logged.
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
