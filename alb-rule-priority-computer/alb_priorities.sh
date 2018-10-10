# Check if an existing ALB rule exists for a given host and return it's priority
function get_current_rule_priority_for_host {
    LISTENER=$1
    SERVICE_DNS_NAME=$2
    REGION=$3

    PRIORITY=$(aws elbv2 describe-rules \
                    --region ${REGION} \
                    --listener-arn ${LISTENER_ARN} \
                    --query "Rules[?contains(Conditions[].Values[], \`${SERVICE_DNS_NAME}\`) == \`true\`].Priority" \
                    --output text)

    echo "${PRIORITY}"
}

# Compute the priority to use for a new rule
# for regional records, we need to increment by 2 because the new service will
# need the first priority value
function compute_new_rule_priority_for_host {
    LISTENER=$1
    INCREMENT=$2

    NEW_PRIORITY=$(aws elbv2 describe-rules \
                  --region ${REGION} \
                  --listener-arn "${LISTENER_ARN}" \
                  | jq -r "[.Rules[].Priority][0:-1] | map(.|tonumber) | max + ${INCREMENT}")

    echo "${NEW_PRIORITY}"
}


##
## Handle assigning a microservice to a common ALB
## The main work here is setting the correct rule priority for the host Mapping
# on the ALB.  The way we accomplish this is by changing the yaml parameters file
# on disk so we have the minimal impact on the overall promotion
##
echo "*** Checking if this service should be attached to a common ALB"

# These parameters are all to handle the rule priority order on the common ALB
$(cat "$CFN_DEPLOY_RULES" | shyaml get-value cloudformation.parameters.ALB &>/dev/null)

if [ $? -eq 0 ]; then
    ALB=$(cat "$CFN_DEPLOY_RULES" | shyaml get-value cloudformation.parameters.ALB)
fi

if [ ! -z "$ALB" ]; then
  ENVNAME=$(cat "$CFN_DEPLOY_RULES" | shyaml get-value cloudformation.parameters.SIGNIANTENV)
  DNSPREFIX=$(cat "$CFN_DEPLOY_RULES" | shyaml get-value cloudformation.parameters.DNSPREFIX)
  DNSREGIONPREFIX=$(cat "$CFN_DEPLOY_RULES" | shyaml get-value cloudformation.parameters.DNSREGIONPREFIX)
  DNSZONE=$(cat "$CFN_DEPLOY_RULES" | shyaml get-value cloudformation.parameters.DNSZONE)

  FQDN=${DNSPREFIX}.${DNSZONE}
  ALBNAME=${ALB}-${ENVNAME}

  echo "Service ${FQDN} is assigned to common ALB ${ALBNAME} in ${REGION}"

  # Does this service have a regional record?
  if [ ! -z "${DNSREGIONPREFIX}" ]; then
    REGIONAL_INCREMENT=1
    REGIONAL_FQDN=${DNSREGIONPREFIX}.${DNSZONE}
    echo "Service regional record ${REGIONAL_FQDN} is assigned to ALB ${ALBNAME} in ${REGION}"
  fi

  # Find the LB ARN.  Needed because we need the listener info and it takes ARN
  LB_ARN=$(aws elbv2 describe-load-balancers \
              --region ${REGION} \
              --names ${ALBNAME} \
              --query 'LoadBalancers[*].LoadBalancerArn' --output text)

  if [ ! -z "${LB_ARN}" ]; then
    echo "The ARN for ${ALBNAME} is ${LB_ARN}"

    # Find the listener ARN.  Rules are defined on the listener
    LISTENER_ARN=$(aws elbv2 describe-listeners \
                      --region ${REGION} \
                      --load-balancer-arn ${LB_ARN} \
                      --query 'Listeners[*].ListenerArn' --output text)

    if [ ! -z "${LISTENER_ARN}" ]; then
      echo "The listener ARN for ${ALBNAME} is ${LISTENER_ARN}"
    else
      echo "Unable to get the listener ARN for ALB ${LB_ARN} in ${REGION}"
    fi
  else
    echo "Unable to describe ALB ${ALBNAME} in ${REGION}"
  fi

  if [ ! -z "${LB_ARN}" ] && [ ! -z "${LISTENER_ARN}" ]; then
    # Do we have an existing rule for the primary DNS name?
    PRIMARY_PRIORITY=$(get_current_rule_priority_for_host "${LISTENER_ARN}" "$FQDN" "$REGION")

    if [ -z "${PRIMARY_PRIORITY}" ]; then
      # No existing rule - generate a new priority
      PRIMARY_PRIORITY=$(compute_new_rule_priority_for_host "${LISTENER_ARN}" "1")

      # if we are adding a new primary rule, we need to add 2 to the regional priority so we get the next+1 rule number
      REGIONAL_INCREMENT=2
    fi
    echo "Rule priority for ${FQDN} is ${PRIMARY_PRIORITY}"
    sed -i.bak "s/LISTENERRULEMAINPRIORITY_COMPUTED_AT_PROMO_TIME/${PRIMARY_PRIORITY}/" ${CFN_DEPLOY_RULES}

    # Do we have a regional record?
    # if we do, re-scan BUT use the priority increment depending on if we added a primary record
    if [ ! -z "${REGIONAL_FQDN}" ]; then
      REGIONAL_PRIORITY=$(get_current_rule_priority_for_host "${LISTENER_ARN}" "$REGIONAL_FQDN" "$REGION")

      if [ -z "${REGIONAL_PRIORITY}" ]; then
        REGIONAL_PRIORITY=$(compute_new_rule_priority_for_host "${LISTENER_ARN}" "${REGIONAL_INCREMENT}")
      fi

      echo "Rule priority for ${REGIONAL_FQDN} is ${REGIONAL_PRIORITY}"
    else
      echo "No regional record for ${FQDN} - subbing in stub value of -1"
      REGIONAL_PRIORITY=-1
    fi

    sed -i.bak "s/LISTENERRULEREGIONALPRIORITY_COMPUTED_AT_PROMO_TIME/${REGIONAL_PRIORITY}/" ${CFN_DEPLOY_RULES}

  else
    echo "*** ERROR ***"
    echo "*** This service is configured to deploy to a common ALB but the ALB and listener information cannot be obtained from AWS"
    exit 1
  fi
fi
