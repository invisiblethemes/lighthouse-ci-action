FROM invisiblethemes/gha-lighthouse-ci:2.1.0
COPY entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
