# Traccar server with this repository's configuration.
#
# The official image keeps its configuration at /opt/traccar/conf/traccar.xml and
# starts with `java -jar tracker-server.jar conf/traccar.xml`.
FROM traccar/traccar:latest

COPY traccar.xml /opt/traccar/conf/traccar.xml

# 8082: web interface and API. 5013: SinoTrack (H02) trackers. 5055: OsmAnd clients.
EXPOSE 8082 5013 5055
