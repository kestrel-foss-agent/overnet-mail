# Debian 12 deliberately keeps the Dovecot 2.3 configuration grammar.
FROM perl:5.40.1-bookworm
ENV DEBIAN_FRONTEND=noninteractive
# Prevent package installation from starting services during the networked build.
RUN printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d && chmod 755 /usr/sbin/policy-rc.d \
 && rm -f /etc/apt/sources.list.d/debian.sources \
 && printf 'deb [check-valid-until=no] https://snapshot.debian.org/archive/debian/20260901T000000Z bookworm main\ndeb [check-valid-until=no] https://snapshot.debian.org/archive/debian-security/20260901T000000Z bookworm-security main\n' > /etc/apt/sources.list \
 && apt-get update && apt-get install -y --no-install-recommends \
    postfix dovecot-imapd dovecot-lmtpd libgmp-dev libpq-dev iproute2 \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY . /src
RUN cpanm --installdeps . && cpanm Mail::IMAPClient@3.43 \
 && groupadd -g 5000 reference-mail && useradd -u 5000 -g 5000 -M reference-mail \
 && mkdir -p /var/lib/reference-mail/alice /var/lib/reference-mail/blind \
 && chown -R 5000:5000 /var/lib/reference-mail \
 && cp lab/real-mta/main.cf lab/real-mta/master.cf /etc/postfix/ \
 && cp lab/real-mta/dovecot.conf /etc/dovecot/dovecot.conf \
 && cp lab/real-mta/users /etc/dovecot/lab-users \
 && chown root:dovecot /etc/dovecot/lab-users \
 && chmod 640 /etc/dovecot/lab-users \
 && cp lab/real-mta/recipients /etc/postfix/lab-recipients \
 && postmap /etc/postfix/lab-recipients \
 && mkdir /lab && cp lab/real-mta/control /lab/control && chmod 755 /lab/control \
 && dpkg-query -W postfix dovecot-core dovecot-imapd dovecot-lmtpd > /lab/versions.txt \
 && perl -MMail::IMAPClient -e 'print "Mail::IMAPClient $Mail::IMAPClient::VERSION\n"' >> /lab/versions.txt
ENV OVERNET_REAL_MTA_LAB=1
ENTRYPOINT ["/lab/control"]
CMD ["check"]
