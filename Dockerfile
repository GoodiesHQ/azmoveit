FROM mcr.microsoft.com/azure-cli:latest

# Install AzCopy v10 (latest via Microsoft redirect).
# Uses Python (always present in the azure-cli image) to extract the tarball so
# there is no dependency on tar or any specific package manager (apk/tdnf).
RUN curl -sSfL https://aka.ms/downloadazcopy-v10-linux -o /tmp/azcopy.tar.gz
RUN python3 -c "import tarfile; tarfile.open('/tmp/azcopy.tar.gz').extractall('/tmp/azcopy')"
RUN find /tmp/azcopy -maxdepth 2 -name azcopy -type f \
         -exec install -m 0755 {} /usr/local/bin/azcopy \;
RUN rm -rf /tmp/azcopy.tar.gz /tmp/azcopy \
RUN azcopy --version

COPY azmoveit.sh /usr/local/bin/azmoveit
RUN chmod +x /usr/local/bin/azmoveit

# Required environment variables for the script to run:
#
# SRC_RG            Resource group of the source storage account
# DST_RG            Resource group of the destination storage account
# SRC_ACCOUNT       Source storage account name
# SRC_SHARE         Source file share name or blob container name
# SRC_TYPE          'file' or 'blob'
# DST_ACCOUNT       Destination storage account name
# DST_SHARE         Destination file share name or blob container name
# DST_TYPE          'file' or 'blob'
#
# Optional:
# SRC_PATH          Path inside source share/container (default: root)
# DST_PATH          Path inside destination share/container (default: root)
# SAS_HOURS         SAS token lifetime in hours (default: 72)
# VERIFY            Run dry-run sync after copy (default: true)
# PRESERVE_PERMISSIONS  Copy SMB ACLs — file-to-file + premium shares only (default: false)
# AZURE_USE_MSI     Log in with managed identity at startup (default: false)
# AZURE_CLIENT_ID   Client ID for user-assigned managed identity (optional)
# SHARE_QUOTA_GB    Quota for new destination file shares in GiB (default: 10240 = 10 TiB)

# Defaults — all can be overridden via environment variables in the Container Apps Job
ENV AZURE_USE_MSI=false \
    SAS_HOURS=72 \
    VERIFY=true \
    PRESERVE_PERMISSIONS=false \
    SHARE_QUOTA_GB=10240

ENTRYPOINT ["/usr/local/bin/azmoveit"]
