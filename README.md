# AWS Three Tier Web Architecture Workshop

## Description: 
This lab is a hands-on walk through of a three-tier web architecture in AWS. We will be creating the necessary network, security, app, and database components and configurations in order to run this architecture in an available and scalable manner.

## Pre-requisites:
1. An AWS account. If you don’t have an AWS account, follow the instructions [here](https://aws.amazon.com/console/) and
click on “Create an AWS Account” button in the top right corner to create one.
1. IDE or text editor of your choice.

## Architecture Overview
![Architecture Diagram](https://github.com/aws-samples/aws-three-tier-web-architecture-workshop/blob/main/application-code/web-tier/src/assets/3TierArch.png)

In this architecture, a public-facing Application Load Balancer forwards client traffic to our web tier EC2 instances. The web tier is running Nginx webservers that are configured to serve a React.js website and redirects our API calls to the application tier’s internal facing load balancer. The internal facing load balancer then forwards that traffic to the application tier, which is written in Node.js. The application tier manipulates data in an Aurora MySQL multi-AZ database and returns it to our web tier. Load balancing, health checks and autoscaling groups are created at each layer to maintain the availability of this architecture.

## Workshop Instructions:

See [WorkshopIntructions.md](WorkshopInstructions.md)


## Security

See [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications) for more information.

## License

This library is licensed under the MIT-0 License. See the LICENSE file.

