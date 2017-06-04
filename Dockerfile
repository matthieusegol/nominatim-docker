# -*-dockerfile-*-

FROM ubuntu:16.04
LABEL maintainer Natan Sągol <m@merlinnot.com>

# Update image
RUN apt-get -qq update && apt-get -qq upgrade -y -o \
      Dpkg::Options::="--force-confold"

# Update locales
USER root
RUN apt-get install -y --no-install-recommends locales
ENV DEBIAN_FRONTEND noninteractive
ENV LANG C.UTF-8
RUN locale-gen en_US.UTF-8
RUN update-locale LANG=en_US.UTF-8

# Add postgresql sources
USER root
RUN apt-get install -y --no-install-recommends wget
RUN echo "deb http://apt.postgresql.org/pub/repos/apt xenial-pgdg main" >> \
      /etc/apt/sources.list && \
    wget --quiet -O - http://apt.postgresql.org/pub/repos/apt/ACCC4CF8.asc | \
      apt-key add -
RUN apt-get -qq update

# Set build variables
ARG BUILD_THREADS=16
ARG BUILD_MEMORY=32GB
ARG PGSQL_VERSION=9.6
ARG POSTGIS_VERSION=2.3
ARG OSM2PGSQL_CACHE=28000

# Set import variables
ARG PBF_URL=https://planet.osm.org/pbf/planet-latest.osm.pbf
ARG REPLICATION_URL=https://planet.osm.org/replication/hour/
ARG IMPORT_ADMINISTRATIVE=false

# Install build dependencies
USER root
RUN apt-get install -y --no-install-recommends \
      apache2 \
      build-essential \
      ca-certificates \
      cmake \
      curl \
      g++ \
      git \
      libapache2-mod-php \
      libboost-dev \
      libboost-filesystem-dev \
      libboost-python-dev \
      libboost-system-dev \
      libbz2-dev \
      libexpat1-dev \
      libgeos-dev \
      libgeos++-dev \
      libpq-dev \
      libproj-dev \
      libxml2-dev\
      openssl \
      osmosis \
      php \
      php-db \
      php-pear \
      php-pgsql \
      postgresql-${PGSQL_VERSION}-postgis-${POSTGIS_VERSION} \
      postgresql-${PGSQL_VERSION}-postgis-scripts \
      postgresql-contrib-${PGSQL_VERSION} \
      postgresql-server-dev-${PGSQL_VERSION} \
      python \
      python-pip \
      python-setuptools \
      sudo \
      zlib1g-dev
RUN pip install --upgrade pip
RUN pip install osmium

# Create nominatim user account
USER root
RUN useradd -d /srv/nominatim -s /bin/bash -m nominatim
ENV USERNAME nominatim
ENV USERHOME /srv/nominatim
RUN chmod a+x ${USERHOME}

# Install Nominatim
USER nominatim
WORKDIR /srv/nominatim
RUN git clone --recursive git://github.com/openstreetmap/Nominatim.git
RUN tee ./Nominatim/settings/local.php << EOF \
      <?php \
      # Paths
      @define('CONST_Postgresql_Version', '${PGSQL_VERSION}'); \
      @define('CONST_Postgis_Version', '${POSTGIS_VERSION}'); \
      @define('CONST_Osm2pgsql_Flatnode_File', '/srv/nominatim/flatnode'); \
      @define('CONST_Pyosmium_Binary', '/usr/local/bin/pyosmium-get-changes'); \
      # Website settings
      @define('CONST_Website_BaseURL', '/nominatim/'); \
      @define('CONST_Replication_Url', 'http://download.geofabrik.de/europe-updates'); \
      @define('CONST_Replication_MaxInterval', '86400'); \
      @define('CONST_Replication_Update_Interval', '86400'); \
      @define('CONST_Replication_Recheck_Interval', '900'); \
    EOF
RUN wget -O Nominatim/data/country_osm_grid.sql.gz \
      http://www.nominatim.org/data/country_grid.sql.gz
RUN mkdir ${USERHOME}/Nominatim/build && \
    cd ${USERHOME}/Nominatim/build && \
    cmake ${USERHOME}/Nominatim && \
    make

# Download data for initial import
USER nominatim
RUN curl -L $PBF_DATA --create-dirs -o /srv/nominatim/src/data.osm.pbf

# Filter country boundaries
USER nominatim
RUN if ${IMPORT_ADMINISTRATIVE}; then \
      osmosis -v \
        --read-pbf-fast workers=${IMPORT_THREADS} /srv/nominatim/src/data.osm.pbf \
        --tf accept-nodes "boundary=administrative" \
        --tf reject-relations \
        --tf reject-ways \
        --write-pbf file=/srv/nominatim/src/nodes.osm.pbf \
    fi
RUN if ${IMPORT_ADMINISTRATIVE}; then \
      osmosis -v \
        --read-pbf-fast workers=${IMPORT_THREADS} /srv/nominatim/src/data.osm.pbf \
        --tf accept-ways "boundary=administrative" \
        --tf reject-relations  \
        --used-node \
        --write-pbf file=/srv/nominatim/src/ways.osm.pbf \
    fi
RUN if ${IMPORT_ADMINISTRATIVE}; then \
      osmosis -v \
        --read-pbf-fast workers=${IMPORT_THREADS} /srv/nominatim/src/data.osm.pbf \
        --tf accept-relations "boundary=administrative" \
        --used-node \
        --used-way \
        --write-pbf file=/srv/nominatim/src/relations.osm.pbf \
    fi
RUN if ${IMPORT_ADMINISTRATIVE}; then \
      osmosis -v \
        --rb /srv/nominatim/src/nodes.osm.pbf outPipe.0=N \
        --rb /srv/nominatim/src/ways.osm.pbf outPipe.0=W \
        --rb /srv/nominatim/src/relations.osm.pbf outPipe.0=R \
        --merge inPipe.0=N inPipe.1=W outPipe.0=NW \
        --merge inPipe.0=NW inPipe.1=R outPipe.0=NWR \
        --wb inPipe.0=NWR file=/srv/nominatim/src/data.osm.pbf \
    fi

# Add postgresql users
USER root
RUN service postgresql start && \
    sudo -u postgres createuser -s nominatim && \
    sudo -u postgres createuser www-data && \
    service postgresql stop

# Tune postgresql configuration for import
USER root
ENV PGCONFIG_URL https://api.pgconfig.org/v1/tuning/get-config
RUN IMPORT_CONFIG_URL = "${PGCONFIG_URL}? \
      format=alter_system& \
      pg_version=${PGSQL_VERSION}& \
      total_ram=${BUILD_MEMORY}& \
      max_connections=$((8 * ${BUILD_THREADS} + 32))& \
      environment_name=DW& \
      include_pgbadger=false" && \
    IMPORT_CONFIG_URL = echo ${IMPORT_CONFIG_URL// /} && \
    service postgresql start && \
    pgsql < curl ${IMPORT_CONFIG_URL} && \
    pgsql < EOF \
        fsync = off \
        full_page_writes = off \
      EOF && \
    service postgresql stop

# Initial import
USER root
RUN service postgresql start && \
    sudo -u nominatim ${USERHOME}/Nominatim/build/utils/setup.php \
      --osm-file /srv/nominatim/src/boundaries.osm.pbf \
      --all \
      --threads ${BUILD_THREADS} \
      --osm2pgsql-cache ${OSM2PGSQL_CACHE} && \
    service postgresql stop

# Set runtime variables
ARG RUNTIME_THREADS=16
ARG RUNTIME_MEMORY=8GB

# Use safe postgresql configuration
USER root
RUN IMPORT_CONFIG_URL = "${PGCONFIG_URL}? \
      format=alter_system& \
      pg_version=${PGSQL_VERSION}& \
      total_ram=${RUNTIME_MEMORY}& \
      max_connections=$((8 * ${RUNTIME_THREADS} + 32))& \
      environment_name=WEB& \
      include_pgbadger=true" && \
    IMPORT_CONFIG_URL = echo ${IMPORT_CONFIG_URL// /} && \
    service postgresql start && \
    pgsql < curl ${IMPORT_CONFIG_URL} && \
    pgsql < EOF \
        fsync = on \
        full_page_writes = on \
      EOF && \
    service postgresql stop

# Configure Apache
USER root
COPY nominatim.conf /etc/apache2/conf-available/nominatim.conf
RUN a2enconf nominatim

# Clean up
USER root
RUN apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# Expose ports
EXPOSE 8080

# Init script
COPY start.sh /srv/nominatim/start.sh
CMD ["/srv/nominatim/start.sh"]
