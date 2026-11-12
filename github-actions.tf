# Lets the GitHub Actions deploy workflow (.github/workflows/deploy.yml) publish
# the site without long-lived AWS keys: GitHub issues a short-lived OIDC token,
# and AWS exchanges it for credentials of the role below.
#
# Creating IAM resources needs more than PowerUserAccess, so apply this file
# with an admin login.

variable "github_repository" {
  description = "GitHub repository (owner/name) allowed to deploy the site"
  type        = string
  default     = "vitkarpov/webkwizards.com"
}

# The repo uses GitHub's immutable OIDC subject, which embeds the owner and
# repository IDs as well as the names, so a deleted-and-recreated repo with the
# same name can't assume the role. Look it up with:
#   gh api repos/vitkarpov/webkwizards.com/actions/oidc/customization/sub
variable "github_oidc_subject_prefix" {
  description = "sub_claim_prefix of the repository's OIDC tokens"
  type        = string
  default     = "repo:vitkarpov@3001791/webkwizards.com@1455052586"
}

# Only one provider per URL can exist in an account. If another project already
# created it, import it instead of creating it:
#   terraform import aws_iam_openid_connect_provider.github \
#     arn:aws:iam::<account-id>:oidc-provider/token.actions.githubusercontent.com
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  # AWS no longer validates these for GitHub, but older provider versions
  # require the field.
  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd",
  ]
}

resource "aws_iam_role" "github_deploy" {
  name        = "webkwizards-github-deploy"
  description = "Assumed by GitHub Actions in ${var.github_repository} to deploy the site"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          # Only workflows running on main. Pull requests and other branches
          # cannot assume the role.
          "token.actions.githubusercontent.com:sub" = "${var.github_oidc_subject_prefix}:ref:refs/heads/main"
        }
      }
    }]
  })
}

# Exactly what deploy.sh needs: sync to the bucket, rewrite rss.xml in place,
# and invalidate the distribution.
resource "aws_iam_role_policy" "github_deploy" {
  name = "deploy-site"
  role = aws_iam_role.github_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.website.arn
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = "${aws_s3_bucket.website.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["cloudfront:CreateInvalidation"]
        Resource = aws_cloudfront_distribution.website.arn
      },
    ]
  })
}

output "github_deploy_role_arn" {
  description = "Role assumed by the GitHub Actions deploy workflow"
  value       = aws_iam_role.github_deploy.arn
}
