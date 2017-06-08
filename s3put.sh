#!/bin/bash -e
#
# License:
#
#     https://github.com/xuwang/bash-s3/blob/master/LICENSE
#
# s3put.sh <bucket> <parent/path> <source>
# e.g. ./s3put.sh my-s3bucket bar.txt foo/bar.txt
# This will upload ./bar.txt to s3://my-s3bucket/foo/bar.txt

# Initilize variables
init_vars() {

  # For signature v4 signning purpose
  timestamp=$(date -u "+%Y-%m-%d %H:%M:%S")
  isoTimpstamp=$(date -ud "${timestamp}" "+%Y%m%dT%H%M%SZ")
  dateScope=$(date -ud "${timestamp}" "+%Y%m%d")
  #dateHeader=$(date -ud "${timestamp}" "+%a, %d %h %Y %T %Z")
  signedHeaders="host;x-amz-content-sha256;x-amz-date;x-amz-security-token"
  service="s3"

  # Get instance auth token from meta-data
  region=$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/document/ | jq -r '.region')
  roleProfile=$(curl -s http://169.254.169.254/latest/meta-data/iam/info \
        | jq -r '.InstanceProfileArn' \
        | sed  's#.*instance-profile/##')
  accountId=$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/document | jq -r .'accountId')

  # KeyId, secret, and token
  accessKeyId=$(curl -s http://169.254.169.254/latest/meta-data/iam/security-credentials/$roleProfile | jq -r '.AccessKeyId')
  secretAccessKey=$(curl -s http://169.254.169.254/latest/meta-data/iam/security-credentials/$roleProfile | jq -r '.SecretAccessKey')
  stsToken=$(curl -s http://169.254.169.254/latest/meta-data/iam/security-credentials/$roleProfile | jq -r '.Token')

  # Empty payload hash (for GET, not for PUT)
  payload=$(sha256_hash /dev/null)

  # Default Host header
  hostHeader="${bucket}.s3-${region}.amazonaws.com"

  # If us-east-1, remove region name: http://docs.aws.amazon.com/general/latest/gr/rande.html
  if [ ${region} = 'us-east-1' ];
  then
    hostHeader="${bucket}.s3.amazonaws.com"
  fi


  # Curl options
  opts="-v -L --fail --retry 5 --retry-delay 3 --silent --show-error"
  # Curl logs
  curlLog=/tmp/curlLog.log
}

# Untilities
hmac_sha256() {
  key="$1"
  data="$2"
  echo -n "$data" | openssl dgst -sha256  -mac HMAC -macopt "$key" | sed 's/^.* //'
}
sha256_hash() {
  echo $(sha256sum "$1" | awk '{print $1}')
}

# Authorization: <Algorithm> Credential=<Access Key ID/Scope>, SignedHeaders=<SignedHeaders>, Signature=<Signature>
# Virtual Hosted-style API: http://docs.aws.amazon.com/AmazonS3/latest/dev/VirtualHosting.html#VirtualHostingLimitations
# Using Example Virtual Hosted–Style Method - this will default to US East and cause a temporary redirect (307)
#     https://${bucket}.s3.amazonaws.com/${filePath}
#    Host: ${bucket}.s3.amazonaws.com" \
# This should avoid the redirect
#  Virtual Hosted–Style Method for a Bucket in a Region Other Than US East
curl_put() {
  curl $opts -H "Host: ${hostHeader}" \
     -H "Authorization: AWS4-HMAC-SHA256 \
	Credential=${accessKeyId}/${dateScope}/${region}/s3/aws4_request, \
	SignedHeaders=${signedHeaders}, Signature=${signature}" \
     -H "x-amz-content-sha256: ${payload}" \
     -H "x-amz-date: ${isoTimpstamp}" \
     -H "x-amz-security-token:${stsToken}" \
     -X PUT -T "${source}" \
     https://${hostHeader}/${filePath}
}

# 1. Canonical request(note Query string is empty, payload is empty for download).
#<HTTPMethod>\n #<CanonicalURI>\n #<CanonicalQueryString>\n #<CanonicalHeaders>\n #<SignedHeaders>\n #<HashedPayload>
#echo "/${bucket}/${cloudConfigYaml}"
canonical_request() {
  echo "PUT"
  echo "/${filePath}"
  echo ""
  echo host:${hostHeader}
  echo "x-amz-content-sha256:${payload}"
  echo "x-amz-date:${isoTimpstamp}"
  echo "x-amz-security-token:${stsToken}"
  echo ""
  echo "${signedHeaders}"
  printf "${payload}"
}
# 2. String to sign
string_to_sign() {
  echo "AWS4-HMAC-SHA256"
  echo "${isoTimpstamp}"
  echo "${dateScope}/${region}/s3/aws4_request"
  printf "$(canonical_request | sha256_hash -)"
}
# 3. Signing key
signing_key() {
  dateKey=$(hmac_sha256 key:"AWS4$secretAccessKey" $dateScope)
  dateRegionKey=$(hmac_sha256 hexkey:$dateKey $region)
  dateRegionServiceKey=$(hmac_sha256 hexkey:$dateRegionKey $service)
  signingKey=$(hmac_sha256 hexkey:$dateRegionServiceKey "aws4_request")
  printf "${signingKey}"
}

# Initlize varables
bucket=$1
dirpath=$2
source=$3
if [[ -z $bucket ]] || [[ -z $dirpath ]] || [[ -z $source ]];
then
  echo "Missing parameters."
  echo "Usage: ./s3put.sh <bucket> <dirpath> <source>"
  exit 1
elif [ ! -f ${source} ]; then
  echo "${source} doesn't exist."
  exit 1
fi
init_vars

fileName=$(basename $source)
filePath=${dirpath}/${fileName}
payload=$(sha256_hash $source)

signature=$(string_to_sign | openssl dgst -sha256 -mac HMAC -macopt hexkey:$(signing_key) | awk '{print $NF}')
curl_put 2>> ${curlLog}

