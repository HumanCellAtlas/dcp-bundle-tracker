#!/usr/bin/env bash

# projectUuid=ecd0c979-a6aa-458a-9dfc-d8cdb183caf7
usage() { echo "Usage: $0 [-p <project uuid>]" 1>&2; exit 1; }

while getopts ":p:" o; do
    case "${o}" in
        p)
            p=${OPTARG}
            ;;
        *)
            usage
            ;;
    esac
done
shift $((OPTIND-1))

if [ -z "${p}" ]; then
    usage
fi

page_size="500"
headers_stash_file="headers.txt"
echo "" > $headers_stash_file

printf "Retrieving ingest exported bundles for project \'%s\'." ${p}
bundleManifests=$(curl -sX GET "http://api.ingest.staging.data.humancellatlas.org/" | \
    jq '._links.projects.href' -r | sed 's/{[^}]*}//' | xargs curl -s | \
    jq '._links.search.href' -r | sed 's/{[^}]*}//' | xargs curl -s | \
    jq '._links.findByUuid.href' -r | sed "s/{[^}]*}/?uuid=${p}/" | xargs curl -s | \
    jq '._links.submissionEnvelopes.href' -r | sed 's/{[^}]*}//' | xargs curl -s | \
    jq '._embedded.submissionEnvelopes[0]._links.bundleManifests.href' -r | sed 's/{[^}]*}//' | xargs curl -s | \
    jq '._links.self.href' -r | sed "s/&size=[0-9]./\&size=${page_size}/")

ingestBundleUuids=""
while true; do
  printf "."
  response=$(curl -sX GET $bundleManifests | \
      jq '{bundleUuids: [._embedded.bundleManifests[].bundleUuid], next: ._links.next.href}')
  if [ -n "$ingestBundleUuids" ]; then
    ingestBundleUuids+=$'\n'
  fi
  ingestBundleUuids+=$(jq -r '.bundleUuids[]' <<< $response)
  bundleManifests=$(jq '.next // empty' -r <<< $response)

  if [ ! $bundleManifests ]; then
    printf "done!\n"
    break;
  fi
done

echo "$ingestBundleUuids" | uniq | sort > ingest-bundle-uuids.txt

printf "Retrieving DSS bundles for project \'%s\'." ${p}

printf "."
dssBundleFqids=$(curl -sX POST \
  "https://dss.staging.data.humancellatlas.org/v1/search?output_format=summary&replica=aws&per_page=500" \
  -H "accept: application/json" \
  -H "Content-Type: application/json" \
  -d "{ \"es_query\": { \"query\": { \"match\": { \"files.project_json.provenance.document_id\": \"${p}\" } } } }" \
  -D ${headers_stash_file} | \
  jq '.results[].bundle_fqid' -r)

  # figure out link from headers stash file
  while read -r line; do
    if [[ $line = link:* ]]; then
      request=$(echo $line | sed 's/^[^<]*<//' | sed 's/>.*$//')
      # echo $request
    fi
  done < $headers_stash_file

# while true; do
#   if [ ! $next ]; then
#     printf "done!\n"
#     break;
#   fi
# done

printf "done!\n"

for item in $dssBundleFqids; do
  dssBundleUuids+=$(echo $item | sed 's/\..*$//')
  dssBundleUuids+=$'\n'
done

echo "$dssBundleUuids" | uniq | sort > dss-bundle-uuids.txt
