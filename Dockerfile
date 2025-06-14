ARG BASE_IMAGE=tomcat:10.1.26-jdk21-temurin-jammy
#referencing a specific image digest pins our unidata tomcat-docker image to platform amd64 (good)
ARG UNIDATA_TOMCAT_IMAGE=unidata/tomcat-docker:10-jdk17@sha256:af7d3fecec753cbd438f25881deeaf48b40ac1f105971d6f300252e104e39fb2
FROM ${UNIDATA_TOMCAT_IMAGE} AS unidata-tomcat-image
FROM ${BASE_IMAGE}

#use approaches and hardened files from https://github.com/Unidata/tomcat-docker
#note: we don't inherit directly from Unidata/tomcat-docker to allow more
#flexibility in building images using different tomcat base images, architectures, etc
RUN apt-get update && \
    apt-get install -y --no-install-recommends  \
        gosu \
        zip \
        unzip \
        && \
    # Cleanup
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* && \
    # Eliminate default web applications
    rm -rf ${CATALINA_HOME}/webapps/* && \
    rm -rf ${CATALINA_HOME}/webapps.dist && \
    # Obscuring server info
    cd ${CATALINA_HOME}/lib && \
    mkdir -p org/apache/catalina/util/ && \
    unzip -j catalina.jar org/apache/catalina/util/ServerInfo.properties \
        -d org/apache/catalina/util/ && \
    sed -i 's/server.info=.*/server.info=Apache Tomcat/g' \
        org/apache/catalina/util/ServerInfo.properties && \
    zip -ur catalina.jar \
        org/apache/catalina/util/ServerInfo.properties && \
    rm -rf org && cd ${CATALINA_HOME} && \
    # Setting restrictive umask container-wide
    echo "session optional pam_umask.so" >> /etc/pam.d/common-session && \
    sed -i 's/UMASK.*022/UMASK           007/g' /etc/login.defs

# Security enhanced web.xml
COPY --from=unidata-tomcat-image ${CATALINA_HOME}/conf/web.xml ${CATALINA_HOME}/conf/

# Security enhanced server.xml
COPY --from=unidata-tomcat-image ${CATALINA_HOME}/conf/server.xml ${CATALINA_HOME}/conf/

ARG ERDDAP_VERSION=2.25.1
ARG ERDDAP_CONTENT_VERSION=1.0.0
ARG ERDDAP_WAR_URL="https://github.com/ERDDAP/erddap/releases/download/v${ERDDAP_VERSION}/erddap.war"
ARG ERDDAP_CONTENT_URL="https://github.com/ERDDAP/erddapContent/archive/refs/tags/content${ERDDAP_CONTENT_VERSION}.zip"
ENV ERDDAP_bigParentDirectory=/erddapData

RUN apt-get update && apt-get install -y unzip xmlstarlet \
    && if ! command -v gosu &> /dev/null; then apt-get install -y gosu; fi \
    && rm -rf /var/lib/apt/lists/*

ARG BUST_CACHE=1
RUN \
    mkdir -p /tmp/dl && \
    curl -fSL "${ERDDAP_WAR_URL}" -o /tmp/dl/erddap.war && \
    unzip /tmp/dl/erddap.war -d ${CATALINA_HOME}/webapps/erddap/ && \
    curl -fSL "${ERDDAP_CONTENT_URL}" -o /tmp/dl/erddapContent.zip && \
    unzip /tmp/dl/erddapContent.zip -d /tmp/dl/erddapContent && \
    find /tmp/dl/erddapContent -type d -name content -exec cp -r "{}" ${CATALINA_HOME} \; && \
    rm -rf /tmp/dl && \
    sed -i 's#</Context>#<Resources cachingAllowed="true" cacheMaxSize="100000" />\n&#' ${CATALINA_HOME}/conf/context.xml && \
    rm -rf /tmp/* /var/tmp/* && \
    mkdir -p ${ERDDAP_bigParentDirectory}

# Java options
COPY files/setenv.sh ${CATALINA_HOME}/bin/setenv.sh

# server.xml fixup
COPY update-server-xml.sh /opt/update-server-xml.sh
RUN /opt/update-server-xml.sh


# -----------------------------
# Install Hadoop (example: 3.3.6)
# -----------------------------
    ENV HADOOP_VERSION=3.3.6
    ENV HADOOP_HOME=/opt/hadoop
    ENV PATH=$PATH:$HADOOP_HOME/bin:$HADOOP_HOME/sbin
    
    RUN wget https://downloads.apache.org/hadoop/common/hadoop-$HADOOP_VERSION/hadoop-$HADOOP_VERSION.tar.gz && \
        tar -xzf hadoop-$HADOOP_VERSION.tar.gz && \
        mv hadoop-$HADOOP_VERSION $HADOOP_HOME && \
        rm hadoop-$HADOOP_VERSION.tar.gz
    
    # -----------------------------
    # Setup Hadoop classpath for Tomcat/ERDDAP
    # -----------------------------
    # Option 1: copy Hadoop jars to Tomcat lib
    RUN cp $HADOOP_HOME/share/hadoop/common/*.jar $CATALINA_HOME/lib/ && \
        cp $HADOOP_HOME/share/hadoop/hdfs/*.jar $CATALINA_HOME/lib/ && \
        cp $HADOOP_HOME/share/hadoop/mapreduce/*.jar $CATALINA_HOME/lib/ && \
        cp $HADOOP_HOME/share/hadoop/yarn/*.jar $CATALINA_HOME/lib/

        

# Default configuration
# Note: Make sure ERDDAP_flagKeyKey is set either in a runtime environment variable or in setup.xml
#       If a value is not set, a random value for ERDDAP_flagKeyKey will be generated at runtime.
ENV ERDDAP_baseHttpsUrl="https://localhost:8443" \
    ERDDAP_emailEverythingTo="nobody@example.com" \
    ERDDAP_emailDailyReportsTo="nobody@example.com" \
    ERDDAP_emailFromAddress="nothing@example.com" \
    ERDDAP_emailUserName="" \
    ERDDAP_emailPassword="" \
    ERDDAP_emailProperties="" \
    ERDDAP_emailSmtpHost="" \
    ERDDAP_emailSmtpPort="" \
    ERDDAP_adminInstitution="Axiom Docker Install" \
    ERDDAP_adminInstitutionUrl="https://github.com/axiom-data-science/docker-erddap" \
    ERDDAP_adminIndividualName="Axiom Docker Install" \
    ERDDAP_adminPosition="Software Engineer" \
    ERDDAP_adminPhone="555-555-5555" \
    ERDDAP_adminAddress="123 Irrelevant St." \
    ERDDAP_adminCity="Nowhere" \
    ERDDAP_adminStateOrProvince="AK" \
    ERDDAP_adminPostalCode="99504" \
    ERDDAP_adminCountry="USA" \
    ERDDAP_adminEmail="nobody@example.com"

COPY entrypoint.sh datasets.d.sh /
ENTRYPOINT ["/entrypoint.sh"]

EXPOSE 8080
CMD ["catalina.sh", "run"]
