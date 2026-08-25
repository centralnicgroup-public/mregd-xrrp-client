ARG RELEASE=13-slim
FROM debian:${RELEASE}
ARG MREGD_GROUP=mregd
ARG MREGD_USER=mregd
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y \
		adduser \
		perl \
		libio-socket-ssl-perl \
		libnet-server-perl \
		ca-certificates \
	&& rm -rf /var/lib/apt/lists/* && apt-get clean \
	&& addgroup --quiet --system $MREGD_GROUP \
	&& adduser --quiet --system --ingroup $MREGD_GROUP --home / --no-create-home $MREGD_USER \
	&& install -d -o $MREGD_USER -g $MREGD_USER /var/run/mregd \
	&& mkdir /opt/mregd
COPY mregd.pl /opt/mregd/
COPY mregd.conf /opt/mregd/mregd.conf
RUN echo "port        0.0.0.0:6490|tcp" >> /opt/mregd/mregd.conf
EXPOSE 6490/tcp
CMD ["/opt/mregd/mregd.pl", "foreground"]
