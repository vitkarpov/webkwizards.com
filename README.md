# WebKwizards.com - Coming Soon Page

A simple static website with "coming soon" page deployed to AWS S3 with CloudFront CDN and HTTPS.

## Architecture

- **S3**: Static website hosting
- **CloudFront**: CDN for HTTPS and global distribution
- **Route 53**: DNS management and domain verification
- **ACM**: SSL/TLS certificate for HTTPS

## Prerequisites

1. AWS CLI configured with appropriate credentials
2. Terraform installed (>= 1.0)
3. Domain `webkwizards.com` registered in AWS Route 53

## Verify Route 53 Hosted Zone

Before deploying, verify that your domain is properly configured in Route 53:

```bash
aws route53 list-hosted-zones --query "HostedZones[?Name=='webkwizards.com.']"
```

This should return your hosted zone with details. If not, you need to create a hosted zone first:

```bash
aws route53 create-hosted-zone --name webkwizards.com --caller-reference $(date +%s)
```

## Deployment Steps

### 1. Initialize Terraform

```bash
terraform init
```

### 2. Review the Plan

```bash
terraform plan
```

This will show you all the resources that will be created:
- S3 bucket for website hosting
- CloudFront distribution
- ACM certificate (with DNS validation)
- Route 53 records for DNS and certificate validation

### 3. Apply the Configuration

```bash
terraform apply
```

Type `yes` when prompted. This will:
1. Create the S3 bucket and upload index.html
2. Request an ACM certificate
3. Create Route 53 records for certificate validation
4. Wait for certificate validation (may take a few minutes)
5. Create CloudFront distribution
6. Create Route 53 A records pointing to CloudFront

**Note**: CloudFront distribution deployment can take 15-30 minutes.

### 4. Verify Deployment

After Terraform completes, check the outputs:

```bash
terraform output
```

You should see:
- `website_url`: Your website URL (https://webkwizards.com)
- `cloudfront_distribution_id`: CloudFront distribution ID
- `s3_bucket_name`: S3 bucket name

### 5. Test the Website

Wait for CloudFront to fully deploy (check status in AWS Console or CLI):

```bash
aws cloudfront get-distribution --id $(terraform output -raw cloudfront_distribution_id) --query 'Distribution.Status'
```

Once status is "Deployed", visit:
- https://webkwizards.com
- https://www.webkwizards.com

## Updating the Website

To update the HTML content:

1. Edit `index.html`
2. Apply changes:
   ```bash
   terraform apply
   ```
3. Invalidate CloudFront cache (optional, for immediate updates):
   ```bash
   aws cloudfront create-invalidation \
     --distribution-id $(terraform output -raw cloudfront_distribution_id) \
     --paths "/*"
   ```

## Cost Estimate

- **Route 53**: $0.50/month per hosted zone + $0.40 per million queries
- **S3**: Negligible for a single HTML file
- **CloudFront**: Free tier includes 1TB data transfer out per month
- **ACM Certificate**: Free

**Estimated monthly cost**: ~$1-2/month (mostly Route 53)

## Cleanup

To destroy all resources:

```bash
terraform destroy
```

Type `yes` when prompted. This will remove:
- CloudFront distribution
- S3 bucket and contents
- Route 53 records (but not the hosted zone)
- ACM certificate

**Note**: The Route 53 hosted zone is not destroyed by Terraform since it's imported via data source.

## Troubleshooting

### Certificate validation stuck

If certificate validation takes too long:
1. Check Route 53 records were created: `aws route53 list-resource-record-sets --hosted-zone-id $(terraform output -raw route53_zone_id)`
2. Verify DNS propagation: `dig _acme-challenge.webkwizards.com`

### Domain not resolving

1. Ensure nameservers in your domain registrar match Route 53:
   ```bash
   aws route53 get-hosted-zone --id $(terraform output -raw route53_zone_id) --query 'DelegationSet.NameServers'
   ```
2. Wait for DNS propagation (can take up to 48 hours)

### CloudFront 403 errors

1. Verify S3 bucket policy allows public access
2. Check that index.html was uploaded: `aws s3 ls s3://$(terraform output -raw s3_bucket_name)`

## Security Notes

- The S3 bucket is configured for public read access (required for website hosting)
- HTTPS is enforced via CloudFront (HTTP requests are redirected to HTTPS)
- TLS 1.2 minimum protocol version is configured

## Files

- `index.html`: The coming soon page
- `main.tf`: Main Terraform configuration
- `variables.tf`: Terraform variables
- `outputs.tf`: Terraform outputs
- `README.md`: This file
