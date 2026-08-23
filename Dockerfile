FROM mysql:26.7

# mysql:8.4 ships mysql, mysqldump, gzip, and gosu - no downloads needed.
COPY scripts/lib.sh scripts/backup-scheduler.sh scripts/acbackup scripts/healthcheck.sh /opt/acbackup/
COPY entrypoint.sh /opt/acbackup/entrypoint.sh
RUN chmod +x /opt/acbackup/backup-scheduler.sh /opt/acbackup/acbackup \
             /opt/acbackup/healthcheck.sh /opt/acbackup/entrypoint.sh \
    && ln -s /opt/acbackup/acbackup /usr/local/bin/acbackup

ENV BACKUP_DIR_BASE=/backups
VOLUME /backups

HEALTHCHECK --interval=60s --timeout=30s --start-period=120s --retries=3 \
  CMD ["/opt/acbackup/healthcheck.sh"]

ENTRYPOINT ["/opt/acbackup/entrypoint.sh"]
CMD ["scheduler"]
