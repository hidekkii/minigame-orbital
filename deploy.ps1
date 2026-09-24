# Deploys game/index.html to a private S3 bucket fronted by CloudFront (OAC).
# Usage: .\deploy.ps1 [-AwsProfile <profile>] [-Region <region>]
param(
  [string]$AwsProfile = $(if ($env:AWS_PROFILE) { $env:AWS_PROFILE } else { 'default' }),
  [string]$Region = 'sa-east-1'
)
$ErrorActionPreference = 'Continue'  # native stderr must not abort; Aws() checks exit codes
$aws = (Get-Command aws -ErrorAction SilentlyContinue).Source
if (-not $aws) { $aws = "$env:LOCALAPPDATA\Programs\Amazon\AWSCLIV2\aws.exe" }
$awsProfile = $AwsProfile
$region = $Region
$account = & $aws sts get-caller-identity --profile $awsProfile --query Account --output text
if ($LASTEXITCODE) { throw "Not signed in to AWS (profile '$awsProfile'). Run: aws login --profile $awsProfile" }
$bucket = "orbit-hop-$account-$region"
$tmp = Join-Path $env:TEMP 'orbit-hop-deploy'
New-Item -ItemType Directory -Force $tmp | Out-Null

function Aws { & $aws @args --profile $awsProfile; if ($LASTEXITCODE) { throw "aws $args failed" } }
function WriteJson($name, $obj) { $p = Join-Path $tmp $name; [IO.File]::WriteAllText($p, ($obj | ConvertTo-Json -Depth 20)); "file://$p" }

# 1. Bucket (private, encrypted by default)
$exists = $true
& $aws s3api head-bucket --bucket $bucket --profile $awsProfile 2>$null; if ($LASTEXITCODE) { $exists = $false }
if (-not $exists) {
  Aws s3api create-bucket --bucket $bucket --region $region --create-bucket-configuration LocationConstraint=$region | Out-Null
}
Aws s3api put-public-access-block --bucket $bucket --public-access-block-configuration 'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true'

# 2. Upload
Aws s3 cp game/index.html "s3://$bucket/index.html" --region $region --content-type 'text/html; charset=utf-8' --cache-control 'max-age=300' | Out-Null

# 3. Origin Access Control
$oacId = (& $aws cloudfront list-origin-access-controls --profile $awsProfile --query "OriginAccessControlList.Items[?Name=='$bucket'].Id" --output text)
if (-not $oacId -or $oacId -eq 'None') {
  $oacCfg = WriteJson 'oac.json' @{ Name = $bucket; OriginAccessControlOriginType = 's3'; SigningBehavior = 'always'; SigningProtocol = 'sigv4' }
  $oacId = Aws cloudfront create-origin-access-control --origin-access-control-config $oacCfg --query 'OriginAccessControl.Id' --output text
}

# 4. Distribution
$distId = (& $aws cloudfront list-distributions --profile $awsProfile --query "DistributionList.Items[?Comment=='$bucket'].Id" --output text)
if (-not $distId -or $distId -eq 'None') {
  $distCfg = WriteJson 'dist.json' @{
    CallerReference = $bucket
    Comment = $bucket
    Enabled = $true
    DefaultRootObject = 'index.html'
    PriceClass = 'PriceClass_All'
    HttpVersion = 'http2and3'
    Origins = @{ Quantity = 1; Items = @(@{
      Id = 's3origin'
      DomainName = "$bucket.s3.$region.amazonaws.com"
      OriginAccessControlId = $oacId
      S3OriginConfig = @{ OriginAccessIdentity = '' }
    }) }
    DefaultCacheBehavior = @{
      TargetOriginId = 's3origin'
      ViewerProtocolPolicy = 'redirect-to-https'
      CachePolicyId = '658327ea-f89d-4fab-a63d-7e88639e58f6'   # Managed-CachingOptimized
      ResponseHeadersPolicyId = '67f7725c-6f97-4210-82d7-5512b31e9d03' # Managed-SecurityHeadersPolicy
      Compress = $true
      AllowedMethods = @{ Quantity = 2; Items = @('GET','HEAD'); CachedMethods = @{ Quantity = 2; Items = @('GET','HEAD') } }
    }
  }
  $distId = Aws cloudfront create-distribution --distribution-config $distCfg --query 'Distribution.Id' --output text
}

# 5. Bucket policy: only this distribution may read
$policy = WriteJson 'policy.json' @{
  Version = '2012-10-17'
  Statement = @(@{
    Sid = 'AllowCloudFrontOAC'
    Effect = 'Allow'
    Principal = @{ Service = 'cloudfront.amazonaws.com' }
    Action = 's3:GetObject'
    Resource = "arn:aws:s3:::$bucket/*"
    Condition = @{ StringEquals = @{ 'AWS:SourceArn' = "arn:aws:cloudfront::${account}:distribution/$distId" } }
  })
}
Aws s3api put-bucket-policy --bucket $bucket --policy $policy

# 6. Invalidate on redeploys
Aws cloudfront create-invalidation --distribution-id $distId --paths '/*' | Out-Null

$domain = Aws cloudfront get-distribution --id $distId --query 'Distribution.DomainName' --output text
Write-Output "Bucket:       $bucket"
Write-Output "Distribution: $distId"
Write-Output "URL:          https://$domain"


