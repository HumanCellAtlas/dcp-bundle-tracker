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
headers_stash_file=".headers.txt"
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

awsRequestUrl="https://dss.staging.data.humancellatlas.org/v1/search?output_format=summary&replica=aws&per_page=500"
awsDssBundleFqids=""
printf "Retrieving AWS DSS bundles for project \'%s\'." ${p}
while true; do
  printf "."
  response=$(curl -sX POST \
    "$awsRequestUrl" \
    -H "accept: application/json" \
    -H "Content-Type: application/json" \
    -d "{ \"es_query\": { \"query\": { \"bool\": { \"must\": [ { \"match\": { \"files.project_json.provenance.document_id\": \"${p}\" } } ], \"must_not\": [ { \"match\": { \"files.analysis_process_json.process_type.text\": \"analysis\" } } ] } } } }" \
    -D ${headers_stash_file} | \
    jq '.results[].bundle_fqid' -r)
  if [ -n "$awsDssBundleFqids" ]; then
    awsDssBundleFqids+=$'\n'
  fi
  awsDssBundleFqids+=$response

  next=""
  while read -r line; do
    if [[ $line = link:* ]]; then
      next=$(echo $line | sed 's/^[^<]*<//' | sed 's/>.*$//')
    fi
  done < $headers_stash_file

  if [ -z $next ]; then
    $next
    printf "done!\n"
    break;
  else
    awsRequestUrl=$next
  fi
done
rm $headers_stash_file

gcpRequestUrl="https://dss.staging.data.humancellatlas.org/v1/search?output_format=summary&replica=gcp&per_page=500"
gcpDssBundleFqids=""
printf "Retrieving GCP DSS bundles for project \'%s\'." ${p}
while true; do
  printf "."
  response=$(curl -sX POST \
    "$gcpRequestUrl" \
    -H "accept: application/json" \
    -H "Content-Type: application/json" \
    -d "{ \"es_query\": { \"query\": { \"bool\": { \"must\": [ { \"match\": { \"files.project_json.provenance.document_id\": \"${p}\" } } ], \"must_not\": [ { \"match\": { \"files.analysis_process_json.process_type.text\": \"analysis\" } } ] } } } }" \
    -D ${headers_stash_file} | \
    jq '.results[].bundle_fqid' -r)
  if [ -n "$gcpDssBundleFqids" ]; then
    gcpDssBundleFqids+=$'\n'
  fi
  gcpDssBundleFqids+=$response

  next=""
  while read -r line; do
    if [[ $line = link:* ]]; then
      next=$(echo $line | sed 's/^[^<]*<//' | sed 's/>.*$//')
    fi
  done < $headers_stash_file

  if [ -z $next ]; then
    $next
    printf "done!\n"
    break;
  else
    gcpRequestUrl=$next
  fi
done
rm $headers_stash_file

printf "Producing diff reports..."

awsDssBundleUuids=""
for item in ${awsDssBundleFqids}; do
  if [ -n "$awsDssBundleUuids" ]; then
    awsDssBundleUuids+=$'\n'
  fi
  awsDssBundleUuids+=$(echo $item | sed 's/\..*$//')
done

echo "$awsDssBundleUuids" | uniq | sort > aws-dss-bundle-uuids.txt

gcpDssBundleUuids=""
for item in ${gcpDssBundleFqids}; do
  if [ -n "$gcpDssBundleUuids" ]; then
    gcpDssBundleUuids+=$'\n'
  fi
  gcpDssBundleUuids+=$(echo $item | sed 's/\..*$//')
done

echo "$gcpDssBundleUuids" | uniq | sort > gcp-dss-bundle-uuids.txt

diff -Bwy --suppress-common-lines ingest-bundle-uuids.txt aws-dss-bundle-uuids.txt > ingest-aws.dss-diff-report.txt
diff -Bwy --suppress-common-lines ingest-bundle-uuids.txt gcp-dss-bundle-uuids.txt > ingest-gcp.dss-diff-report.txt
diff -Bwy --suppress-common-lines aws-dss-bundle-uuids.txt gcp-dss-bundle-uuids.txt > aws-gcp-dss-diff-report.txt
printf "done!\n"
