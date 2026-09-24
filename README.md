# Orbit Hop

**English** | [Português (BR)](README.pt-BR.md)

A tiny one-button arcade game in a single HTML file. Your comet circles a star — hop between the inner and outer orbit to grab stardust and dodge meteors.

**Play:** https://d20580lqom8vrn.cloudfront.net

## Controls

Tap, click, or press <kbd>Space</kbd> to hop between orbits.

## Run locally

Open `game/index.html` in a browser. No build step, no dependencies.

## Deploy to AWS

Hosted on a private S3 bucket behind CloudFront (Origin Access Control, HTTPS only).

```powershell
aws login --profile <your-profile>
powershell -ExecutionPolicy Bypass -File .\deploy.ps1 -AwsProfile <your-profile> -Region <your-region>
```

The script is idempotent: it creates the bucket, OAC and distribution on first run, and on later runs just uploads `index.html` and invalidates the CloudFront cache.
