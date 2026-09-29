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

# 6. Leaderboard backend: DynamoDB table + Lambda (function URL, IAM auth) behind CloudFront /api/*
$table = 'minigame-orbital-scores'
$fn = 'minigame-orbital-api'
$roleName = 'minigame-orbital-api-role'
$distArn = "arn:aws:cloudfront::${account}:distribution/$distId"

& $aws dynamodb describe-table --table-name $table --region $region --profile $awsProfile 2>$null | Out-Null
if ($LASTEXITCODE) {
  Aws dynamodb create-table --table-name $table --region $region --billing-mode PAY_PER_REQUEST `
    --attribute-definitions 'AttributeName=pk,AttributeType=S' 'AttributeName=sk,AttributeType=S' `
    --key-schema 'AttributeName=pk,KeyType=HASH' 'AttributeName=sk,KeyType=RANGE' | Out-Null
  Aws dynamodb wait table-exists --table-name $table --region $region
}
$tableArn = Aws dynamodb describe-table --table-name $table --region $region --query 'Table.TableArn' --output text

$roleArn = & $aws iam get-role --role-name $roleName --profile $awsProfile --query 'Role.Arn' --output text 2>$null
$newRole = $false
if ($LASTEXITCODE) {
  $trust = WriteJson 'trust.json' @{
    Version = '2012-10-17'
    Statement = @(@{
      Effect = 'Allow'
      Principal = @{ Service = 'lambda.amazonaws.com' }
      Action = 'sts:AssumeRole'
      Condition = @{ StringEquals = @{ 'aws:SourceAccount' = $account } }
    })
  }
  $roleArn = Aws iam create-role --role-name $roleName --assume-role-policy-document $trust --query 'Role.Arn' --output text
  Aws iam attach-role-policy --role-name $roleName --policy-arn 'arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole'
  $newRole = $true
}
$rolePolicy = WriteJson 'role-policy.json' @{
  Version = '2012-10-17'
  Statement = @(@{ Effect = 'Allow'; Action = @('dynamodb:Query', 'dynamodb:PutItem'); Resource = $tableArn })
}
Aws iam put-role-policy --role-name $roleName --policy-name scores-table --policy-document $rolePolicy
if ($newRole) { Start-Sleep -Seconds 10 }  # let the new role propagate before Lambda uses it

$zip = Join-Path $tmp 'api.zip'
Compress-Archive -Path api\index.mjs -DestinationPath $zip -Force
& $aws lambda get-function --function-name $fn --region $region --profile $awsProfile 2>$null | Out-Null
if ($LASTEXITCODE) {
  for ($i = 0; $i -lt 6; $i++) {
    & $aws lambda create-function --function-name $fn --region $region --profile $awsProfile --runtime nodejs22.x `
      --handler index.handler --role $roleArn --zip-file "fileb://$zip" --memory-size 256 --timeout 10 `
      --environment "Variables={TABLE_NAME=$table}" 2>$null | Out-Null
    if (-not $LASTEXITCODE) { break }
    Start-Sleep -Seconds 5
  }
  if ($LASTEXITCODE) { throw "lambda create-function failed" }
  Aws lambda wait function-active-v2 --function-name $fn --region $region
} else {
  Aws lambda update-function-code --function-name $fn --region $region --zip-file "fileb://$zip" | Out-Null
  Aws lambda wait function-updated-v2 --function-name $fn --region $region
}

$fnUrl = & $aws lambda get-function-url-config --function-name $fn --region $region --profile $awsProfile --query FunctionUrl --output text 2>$null
if ($LASTEXITCODE) {
  $fnUrl = Aws lambda create-function-url-config --function-name $fn --region $region --auth-type AWS_IAM --query FunctionUrl --output text
}
$fnDomain = ([Uri]$fnUrl).Host

# Only this CloudFront distribution may call the function URL (needs both permissions).
$fnPolicy = & $aws lambda get-policy --function-name $fn --region $region --profile $awsProfile --query Policy --output text 2>$null
if ("$fnPolicy" -notmatch 'CloudFrontInvokeUrl') {
  Aws lambda add-permission --function-name $fn --region $region --statement-id CloudFrontInvokeUrl `
    --action lambda:InvokeFunctionUrl --principal cloudfront.amazonaws.com --source-arn $distArn | Out-Null
}
if ("$fnPolicy" -notmatch 'CloudFrontInvoke"') {
  Aws lambda add-permission --function-name $fn --region $region --statement-id CloudFrontInvoke `
    --action lambda:InvokeFunction --principal cloudfront.amazonaws.com --source-arn $distArn --invoked-via-function-url | Out-Null
}

$lambdaOacName = "$fn-oac"
$lambdaOac = (& $aws cloudfront list-origin-access-controls --profile $awsProfile --query "OriginAccessControlList.Items[?Name=='$lambdaOacName'].Id" --output text)
if (-not $lambdaOac -or $lambdaOac -eq 'None') {
  $oacCfg = WriteJson 'oac-lambda.json' @{ Name = $lambdaOacName; OriginAccessControlOriginType = 'lambda'; SigningBehavior = 'always'; SigningProtocol = 'sigv4' }
  $lambdaOac = Aws cloudfront create-origin-access-control --origin-access-control-config $oacCfg --query 'OriginAccessControl.Id' --output text
}

$current = (& $aws cloudfront get-distribution-config --id $distId --profile $awsProfile --output json) -join "`n" | ConvertFrom-Json
$cfg = $current.DistributionConfig
if (-not ($cfg.Origins.Items | Where-Object { $_.Id -eq 'lambda-api' })) {
  $cfg.Origins.Items = @($cfg.Origins.Items) + @([pscustomobject]@{
    Id = 'lambda-api'
    DomainName = $fnDomain
    OriginPath = ''
    CustomHeaders = @{ Quantity = 0 }
    CustomOriginConfig = @{
      HTTPPort = 80; HTTPSPort = 443; OriginProtocolPolicy = 'https-only'
      OriginSslProtocols = @{ Quantity = 1; Items = @('TLSv1.2') }
      OriginReadTimeout = 30; OriginKeepaliveTimeout = 5
    }
    ConnectionAttempts = 3
    ConnectionTimeout = 10
    OriginShield = @{ Enabled = $false }
    OriginAccessControlId = $lambdaOac
  })
  $cfg.Origins.Quantity = @($cfg.Origins.Items).Count
  $cfg.CacheBehaviors = [pscustomobject]@{ Quantity = 1; Items = @([pscustomobject]@{
    PathPattern = '/api/*'
    TargetOriginId = 'lambda-api'
    ViewerProtocolPolicy = 'https-only'
    CachePolicyId = '4135ea2d-6df8-44a3-9df3-4b5a84be39ad'          # Managed-CachingDisabled
    OriginRequestPolicyId = 'b689b0a8-53d0-40ab-baf2-68738e2966ac'  # Managed-AllViewerExceptHostHeader
    Compress = $true
    SmoothStreaming = $false
    FieldLevelEncryptionId = ''
    TrustedSigners = @{ Enabled = $false; Quantity = 0 }
    TrustedKeyGroups = @{ Enabled = $false; Quantity = 0 }
    LambdaFunctionAssociations = @{ Quantity = 0 }
    FunctionAssociations = @{ Quantity = 0 }
    AllowedMethods = @{ Quantity = 7; Items = @('GET','HEAD','OPTIONS','PUT','POST','PATCH','DELETE')
                        CachedMethods = @{ Quantity = 2; Items = @('GET','HEAD') } }
  }) }
  $distUpdate = WriteJson 'dist-update.json' $cfg
  Aws cloudfront update-distribution --id $distId --if-match $current.ETag --distribution-config $distUpdate | Out-Null
  Write-Output 'Added /api/* to CloudFront; waiting for it to deploy...'
  Aws cloudfront wait distribution-deployed --id $distId
}

# 7. Invalidate on redeploys
Aws cloudfront create-invalidation --distribution-id $distId --paths '/*' | Out-Null

$domain = Aws cloudfront get-distribution --id $distId --query 'Distribution.DomainName' --output text
Write-Output "Bucket:       $bucket"
Write-Output "Distribution: $distId"
Write-Output "URL:          https://$domain"


