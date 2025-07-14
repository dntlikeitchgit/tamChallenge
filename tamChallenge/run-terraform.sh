#!/bin/bash

APPLY_FIRST_PATH="/Users/judch01/terraform/wiz-eks-tasky"
APPLY_SECOND_PATH="/Users/judch01/terraform/wiz-eks-tasky/tasky-deploy"
APPLY=false
DESTROY=false
FAIL=true

INTENTION=$(echo "${1}" | tr "[:lower:]" "[:upper:]")

if [[ -z $1 ]]
  then
#echo "Setting fail true in 'initial check'"
    FAIL=true
#    echo "Input argument is zero length"
elif [ "$INTENTION" == "APPLY" ]
  then
    APPLY=true
#    echo "Apply $APPLY"
elif [ "$INTENTION" == "DESTROY" ]
  then
    DESTROY=true
#    echo "Destroy $DESTROY"
else
#echo "Setting fail true in 'else'"
  FAIL=true
fi

#echo "Fail: $FAIL"
#echo "Apply: $APPLY"
#echo "Destroy: $DESTROY"

#if ! $DESTROY; then echo "This is expected"; elif $DESTROY; then echo "This is not expected"; fi

if $FAIL && ! $APPLY && ! $DESTROY
  then
    echo 'Invalid option... Provide either: "apply" or "destroy"'
    exit
elif $APPLY &&  ! $DESTROY 
  then
    cd $APPLY_FIRST_PATH
    echo "Applying Terraform in $APPLY_FIRST_PATH..."
    terraform apply -auto-approve
    cd $APPLY_SECOND_PATH
    echo "Applying Terraform in $APPLY_SECOND_PATH..."
    terraform apply -auto-approve
elif $DESTROY && ! $APPLY
  then
    cd $APPLY_SECOND_PATH
    echo "Destroying Terraform in $APPLY_SECOND_PATH..."
    terraform destroy -auto-approve
    cd $APPLY_FIRST_PATH
    echo "Destroying Terraform in $APPLY_FIRST_PATH..."
    terraform destroy -auto-approve
else
    echo "Something went wrong... You shouldn't be seeing this... Time to debug!"
    exit 1
fi
