#!/bin/bash
clear

# Run aws configure with the provided values
aws configure set aws_access_key_id "<redacted>"
aws configure set aws_secret_access_key "<redacted>"
aws configure set default.region "us-east-2"

eksctl create cluster --config-file=ekscluster-config.yaml

AWS_PAGER="" aws eks list-clusters --region us-east-2 --query "clusters[]" --output text
read -p "Change context to which cluster ?" cluster_name
aws eks update-cluster-config --region us-east-2 --name $cluster_name --resources-vpc-config endpointPublicAccess=true,endpointPrivateAccess=true
