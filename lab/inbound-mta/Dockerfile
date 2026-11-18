# A separate disposable inbound lab. No Dovecot or outbound delivery transport.
FROM perl:5.40.1-bookworm
ENV DEBIAN_FRONTEND=noninteractive
# Only the build has network access. Pin Debian packages to one dated archive,
# and prevent package scripts from starting any service while installing them.
RUN printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d && chmod 755 /usr/sbin/policy-rc.d \
 && rm -f /etc/apt/sources.list.d/debian.sources \
 && printf 'deb [check-valid-until=no] https://snapshot.debian.org/archive/debian/20260901T000000Z bookworm main\ndeb [check-valid-until=no] https://snapshot.debian.org/archive/debian-security/20260901T000000Z bookworm-security main\n' > /etc/apt/sources.list \
 && apt-get update && apt-get install -y --no-install-recommends \
    postfix postgresql-15 postgresql-client-15 python3-dev python3-venv \
    libmilter-dev libgmp-dev libpq-dev build-essential iproute2 util-linux procps \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY . /src
RUN cpanm --installdeps . \
 && mkdir -p /lab \
 && python3 -m venv /lab/venv \
 && /lab/venv/bin/pip install --require-hashes -r lab/inbound-mta/requirements.txt \
 && /lab/venv/bin/python -c 'import Milter, sqlite3' \
 && perl -MDBD::Pg -MDBD::SQLite -MOvernet::Mail::Store -Ilib -e 1 \
 && bash scripts/prepare-syscall-headers.sh /lab/syscall \
 && groupadd -g 5000 intake && useradd -u 5000 -g intake -M -s /usr/sbin/nologin intake \
 && cp lab/inbound-mta/main.cf lab/inbound-mta/master.cf /etc/postfix/ \
 && cp lab/inbound-mta/recipients /etc/postfix/lab-recipients \
 && postmap /etc/postfix/lab-recipients \
 && install -o postfix -g postfix -m 640 /dev/null /var/log/inbound-postfix.log \
 && install -o root -g root -m 755 lab/inbound-mta/control /lab/control \
 && chmod 755 lab/inbound-mta/pipe-delivery \
 && install -d -o intake -g postfix -m 2750 /lab/milter \
 && dpkg-query -W postfix postgresql-15 postgresql-client-15 python3 libmilter1.0.1 > /lab/versions.txt \
 && /lab/venv/bin/pip freeze >> /lab/versions.txt \
 && perl -MDBD::Pg -MDBD::SQLite -e 'print "DBD::Pg $DBD::Pg::VERSION\nDBD::SQLite $DBD::SQLite::VERSION\n"' >> /lab/versions.txt
ENV OVERNET_INBOUND_MTA_LAB=1
ENV PERL5LIB=/lab/syscall:/src/lib
ENTRYPOINT ["/lab/control"]
CMD ["check"]
