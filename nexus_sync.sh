#!/bin/bash

SOURCE_NEXUS="" # указываем адресс источника в формате https://nexus.example.ru
SOURCE_REPO=""  # имя репозитория
SOURCE_USER='' #Логин
SOURCE_PASSWORD='' #Пароль

TARGET_NEXUS="" # указываем адресс таргета в формате https://nexus_new.example.ru
TARGET_REPO="$SOURCE_REPO" # имя репозитория
TARGET_USER='' #Логин
TARGET_PASSWORD='' #Пароль

ROOT_GROUP="org.orglot" #Указываем корневвую директорию которую переносим
TMP_DIR=$(mktemp -d)
LOG_FILE="nexus_sync_${SOURCE_REPO}_$(date +%F_%H-%M-%S).log"

exec > >(tee -a "$LOG_FILE") 2>&1

echo "==== Nexus Migration Script Started at $(date) ===="
echo "Source: $SOURCE_REPO → Target: $TARGET_REPO"
echo "Log file: $LOG_FILE"
echo "Using temp dir: $TMP_DIR"
echo

MAVEN_SETTINGS="$TMP_DIR/settings.xml"
cat > "$MAVEN_SETTINGS" << EOF
<settings>
  <servers>
    <server>
      <id>target</id>
      <username>$TARGET_USER</username>
      <password>$TARGET_PASSWORD</password>
    </server>
  </servers>
</settings>
EOF

process_components() {
    local continuation_token="$1"
    local params="repository=$SOURCE_REPO"
    [ -n "$continuation_token" ] && params+="&continuationToken=$continuation_token"

    echo "[INFO] Fetching components (token: ${continuation_token:-NONE})"
    response=$(curl -fsS -u "$SOURCE_USER:$SOURCE_PASSWORD" "$SOURCE_NEXUS/service/rest/v1/components?$params") || {
        echo "[ERROR] Failed to fetch components"
        exit 1
    }

    items=$(echo "$response" | jq -c '.items[]?')
    next_token=$(echo "$response" | jq -r '.continuationToken // empty')

    while IFS= read -r item; do
        group=$(echo "$item" | jq -r '.group // ""')
        artifact=$(echo "$item" | jq -r '.name')
        version=$(echo "$item" | jq -r '.version')
        assets=$(echo "$item" | jq -c '.assets[]?')

        [[ "$group" != "$ROOT_GROUP"* ]] && continue

        group_path=$(echo "$group" | tr '.' '/')
        base_dir="$TMP_DIR/$group_path/$artifact/$version"
        mkdir -p "$base_dir"

        echo "[INFO] Processing $group:$artifact:$version"

        while IFS= read -r asset; do
            path=$(echo "$asset" | jq -r '.path')
            download_url=$(echo "$asset" | jq -r '.downloadUrl')
            filename=$(basename "$path")

            echo "[INFO]   Downloading: $path"
            curl -fsS -u "$SOURCE_USER:$SOURCE_PASSWORD" -o "$base_dir/$filename" "$download_url" || {
                echo "[ERROR]   Failed to download $path"
                continue
            }
        done <<< "$assets"

        main_jar=$(ls "$base_dir" | grep -E "$artifact-$version\.jar$" | head -1)
        pom_file=$(ls "$base_dir" | grep -E "$artifact-$version\.pom$" | head -1)

        if [ -z "$pom_file" ]; then
            echo "[ERROR]   POM not found for $group:$artifact:$version"
            continue
        fi

        deploy_file="$pom_file"
        [ -n "$main_jar" ] && deploy_file="$main_jar"

        echo "[INFO]   Uploading: $group:$artifact:$version"
        mvn -s "$MAVEN_SETTINGS" deploy:deploy-file \
            -Dfile="$base_dir/$deploy_file" \
            -DpomFile="$base_dir/$pom_file" \
            -DrepositoryId=target \
            -Durl="$TARGET_NEXUS/repository/$TARGET_REPO" \
            -DgroupId="$group" \
            -DartifactId="$artifact" \
            -Dversion="$version" \
            -DgeneratePom=false \
             && {
                 echo "[SUCCESS]   Uploaded $group:$artifact:$version"
                 rm -rf "$base_dir"
             } || {
                 echo "[ERROR]   Failed to upload $group:$artifact:$version"
             }

    done <<< "$items"

    [ -n "$next_token" ] && process_components "$next_token"
}

process_components ""
rm -rf "$TMP_DIR"
echo "==== Migration completed at $(date) ===="
