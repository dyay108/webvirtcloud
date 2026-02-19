FROM phusion/baseimage:noble-1.0.2

ENV DEBIAN_FRONTEND=noninteractive
ENV WVC_APP_DIR=/srv/webvirtcloud
ENV WVC_DATA_DIR=/data

EXPOSE 80
EXPOSE 6080

# baseimage init
CMD ["/sbin/my_init"]

RUN echo 'APT::Get::Clean=always;' >> /etc/apt/apt.conf.d/99AutomaticClean

RUN apt-get update -qqy && \
    apt-get -qyy install --no-install-recommends \
      git \
      python3-venv \
      python3-dev \
      python3-lxml \
      libvirt-dev \
      zlib1g-dev \
      nginx \
      pkg-config \
      gcc \
      g++ \
      make \
      libldap2-dev \
      libssl-dev \
      libsasl2-dev \
      libsasl2-modules \
      sassc \
      libsass-dev && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# App code lives in the image
COPY . ${WVC_APP_DIR}
WORKDIR ${WVC_APP_DIR}
RUN chown -R www-data:www-data ${WVC_APP_DIR}

# Python venv + deps
RUN python3 -m venv venv && \
    . venv/bin/activate && \
    pip3 install -U pip wheel && \
    pip3 install -r conf/requirements.txt && \
    pip3 cache purge

RUN mkdir -p /opt/wvc-seed && \
    cp -a webvirtcloud/settings.py.template /opt/wvc-seed/settings.py && \
    cp -a static /opt/wvc-seed/static || true

RUN mkdir -p ${WVC_DATA_DIR} && chown -R www-data:www-data ${WVC_DATA_DIR}

RUN printf "\n%s" "daemon off;" >> /etc/nginx/nginx.conf && \
    rm -f /etc/nginx/sites-enabled/default && \
    chown -R www-data:www-data /var/lib/nginx
COPY conf/nginx/webvirtcloud.conf /etc/nginx/conf.d/

# Seed + migrate on boot (runs once per container start; idempotent)
RUN mkdir -p /etc/my_init.d && \
    bash -lc 'cat > /etc/my_init.d/10-webvirtcloud-seed.sh <<'"'"'SH'"'"'
#!/bin/bash
set -euo pipefail

APP_DIR="${WVC_APP_DIR:-/srv/webvirtcloud}"
DATA_DIR="${WVC_DATA_DIR:-/data}"

mkdir -p "$DATA_DIR"
chown -R www-data:www-data "$DATA_DIR"

# Generate SECRET_KEY once and persist it on the host mount
if [ ! -f "$DATA_DIR/secret_key" ]; then
  KEY="$("$APP_DIR/venv/bin/python" -c "from django.core.management.utils import get_random_secret_key; print(get_random_secret_key())")"
  printf "%s" "$KEY" > "$DATA_DIR/secret_key"
  chown www-data:www-data "$DATA_DIR/secret_key"
fi
SECRET_KEY="$(cat "$DATA_DIR/secret_key")"

# Seed settings.py into /data if missing
if [ ! -f "$DATA_DIR/settings.py" ]; then
  cp -a /opt/wvc-seed/settings.py "$DATA_DIR/settings.py"
  chown www-data:www-data "$DATA_DIR/settings.py"
fi

# Seed static into /data if missing
if [ ! -d "$DATA_DIR/static" ] && [ -d /opt/wvc-seed/static ]; then
  cp -a /opt/wvc-seed/static "$DATA_DIR/static"
  chown -R www-data:www-data "$DATA_DIR/static"
fi

# Ensure the running app uses the persisted settings
cp -a "$DATA_DIR/settings.py" "$APP_DIR/webvirtcloud/settings.py"
chown www-data:www-data "$APP_DIR/webvirtcloud/settings.py"

# Best-effort: ensure SECRET_KEY is set (works if template contains SECRET_KEY = "")
sed -i "s/^SECRET_KEY *= *\"\"/SECRET_KEY = \"${SECRET_KEY//\//\\/}\"/" "$APP_DIR/webvirtcloud/settings.py" || true

# Run DB init/migrations at runtime (safe to run repeatedly)
cd "$APP_DIR"
. venv/bin/activate
python3 manage.py migrate --noinput || true
python3 manage.py collectstatic --noinput || true
SH
chmod +x /etc/my_init.d/10-webvirtcloud-seed.sh'

# Runit services (keep yours)
RUN mkdir -p /etc/service/nginx /etc/service/nginx-log-forwarder /etc/service/webvirtcloud /etc/service/novnc
COPY conf/runit/nginx                /etc/service/nginx/run
COPY conf/runit/nginx-log-forwarder  /etc/service/nginx-log-forwarder/run
COPY conf/runit/novncd.sh            /etc/service/novnc/run
COPY conf/runit/webvirtcloud.sh      /etc/service/webvirtcloud/run

VOLUME ["/data"]
