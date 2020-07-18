# Prepare project
## Introduction

In this series of posts, I'm going to show how to set up the CI/CD environment using AWS and CircleCI.
As a final result, we will get the pipeline that:
* runs tests after each commit;
* builds containers from development and master branches;
* pushes them into the ECR;
* redeploys  development and production EC2 instances from the development and master containers respectively.

This guide consists of three parts:
* ➡️ **Preparation** - where I'll explain this workflow, and show how to prepare an application for it 
* AWS - this chart is about how to set up the AWS environment from scratch;
* CircleCI - here I'll demonstrate how to automatize deployment process using [circleci.com](circleci.com)

## Prepare the application

As an example let's take a simple API server with a one route written on the Elixir. I will not explain here how 
to create it, there is a fantastic article [there](https://dev.to/jonlunsford/elixir-building-a-small-json-endpoint-with-plug-cowboy-and-poison-1826)
Or you can use [my application](https://github.com/evanilukhin/simple_plug_server), it is already configured and prepared. 
There I'll focus only on the specific moments that are needed to prepare the server for work in this environment. 

!Image with the routes results.

This Elixir application I am going to deploy using mechanism of [releases](https://hexdocs.pm/mix/Mix.Tasks.Release.html).
Briefly, it generates an artifact that contains the Erlang VM and its runtime, compiled source code and launch scripts.

Let me make a little digress to tell about the methodology I'm trying to follow for designing microservices. 
I'm talking about [12 factor app manifest](https://12factor.net). It's a set of recommendations for building software-as-a-service apps that:

    * Use declarative formats for setup automation, to minimize time and cost for new developers joining the project;
    * Have a clean contract with the underlying operating system, offering maximum portability between execution environments;
    * Are suitable for deployment on modern cloud platforms, obviating the need for servers and systems administration;
    * Minimize divergence between development and production, enabling continuous deployment for maximum agility;
    * And can scale up without significant changes to tooling, architecture, or development practices.
 
And [one of this principles](https://12factor.net/config) recommends us to store configurable parameters(ports, api keys, services addresses, etc.) 
in system environment variables. To configure our release application using env variables we should create the file 
`config/releases.exs` and describe these variables:

```elixir
import Config

config :simple_plug_server, port: System.get_env("PORT")
```

More about different config files in Elixir applications you can find [here](https://elixir-lang.org/getting-started/mix-otp/config-and-releases.html#configuring-releases) 
and [here](https://hexdocs.pm/mix/Mix.Tasks.Release.html#module-application-configuration)

Next thing I would like to cover is the starting an application. The most common way is to use a special shell script
for it that contains different preparation steps like waiting a database, initializing system variables, etc. Also
it makes your Docker file more expressive. I think you will agree that `CMD ["bash", "./simple_plug_server/entrypoint.sh"]`
looks better than `CMD ["bash", "cmd1", "arg1", "arg2", ";" "cmd2", "arg1", "arg2", "arg3"]`. The entrypoint script for
this server is very simple:
```shell script
#!/bin/sh

bin/simple_plug_server start
```

This application works in the docker container so the last command `bin/simple_plug_server start` starts
app without daemonizing it and writes logs right into the stdout. That is allow us to [gather logs](https://12factor.net/logs)
simpler.

And the last step let's create the [Dockerfile](Dockerfile) that builds result container. I prefer to use two steps builds
for Elixir applications because result containers are very thin(approx. 50-70MB).
```dockerfile
FROM elixir:1.10.0-alpine as build

# install build dependencies
RUN apk add --update git build-base

# prepare build dir
RUN mkdir /app
WORKDIR /app

# install hex + rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# set build ENV
ENV MIX_ENV=prod

# install mix dependencies
COPY mix.exs mix.lock ./
COPY config config
RUN mix deps.get
RUN mix deps.compile

# build project
COPY lib lib
RUN mix compile

# build release
RUN mix release

# prepare release image
FROM alpine:3.12 AS app
RUN apk add --update bash openssl

RUN mkdir /app
WORKDIR /app

COPY --from=build /app/_build/prod/rel/simple_plug_server ./
COPY --from=build /app/lib/simple_plug_server/entrypoint.sh ./simple_plug_server/entrypoint.sh
RUN chown -R nobody: /app
USER nobody

ENV HOME=/app

CMD ["bash", "./simple_plug_server/entrypoint.sh"]
```

Finally you can build it using `docker build .`, and  run `docker run -it -p 4000:4000 -e PORT=4000 {IMAGE_ID}`. 
The server will be available on the `localhost:4000` and will write logs to the stdout. 🎉

## P.S. One word about the using workflow

When you developing applications in "real life" you usually(but not always), sooner or later, 
found that you need to:
* run automatic tests;
* run different checks(code coverage, security audit, code style, etc.);
* test how a feature works before you deploy it to the production;
* deliver results as fast as possible.

I'm going to show how it can work on the workflow with two main branches: 
* master - has tested, production ready code(deploys on a production server)
* development - based on the master and also has changes that being tested now(deploys on a development server)

When you developing a new feature the process consists of the nest steps;
1) Create branch for a feature from master
2) Work
3) Push this feature
4) **Optionally** Run tests, checks, etc. for this branch 
5) In case of success merge this branch to the development
6) Run everything again and redeploy the development server
7) Test it manually
8) Merge feature to the production
9) Redeploy production

# Build and and push images

This chapter is about setting up the AWS environment. At the end of it you will have completely deployed application.
Let's start. Almost all steps will be inside the [Amazon Container Services](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/Welcome.html)
space.

## Prepare environment for containers

### Create IAM user

When you log in the aws console first time you are log in under the root user. You have full access to every service and 
the billing management console. To secure interaction with AWS it is a good practice to create a new user inside 
the group that has only required permissions. 
    
A few words about managing permissions. There are two main ways to add them to users through [groups](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_groups.html)
and [roles](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles.html). The main difference is in that groups is 
a collection of users with same policies. Roles, in turn, can be used to delegate access not only to users but also 
to other services and applications, we will use both. Let's create them

! Window with button

On the second step select the next policies

* AmazonEC2ContainerRegistryFullAccess 
* AWSCodeDeployRoleForECS 
* AmazonEC2ContainerServiceFullAccess 
* AmazonECSTaskExecutionRolePolicy 

! Group after creation.png

Then create the role that we will give to ecs to deploy our containers to ec2 instances 

! Create role window

and on the second step select in policies `AmazonEC2ContainerServiceforEC2Role`

! Result

More about it is showed [there](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/instance_IAM_role.html)

And finally let's add a new user and add to the previously generated

Create user that has only programmatic access because we will use it only from the circleci and terminal.

Generate access keys. Save them, they will need you later


### Create ECR

a place where we will store containers an from where they will be deployed. Just go to the ECL and 
click on the "Create repository" you will see the window where you should select the name for the repository. Other 
settings use by default

!ECR_create.png

!ECR after creation.png

Great! You have repository and all required credentials to build and push images. Time to automatize it.

## Configuring Circle CI

The main idea is to run tests after each commit for all branches and deploy after changes in the development and master.

Before you start to configure the pipeline, you will need to prepare the application
following this fantastic [getting started](https://circleci.com/docs/2.0/getting-started/#section=getting-started) page.

### Tests

The most popular use case of the Circle CI that I've seen is running tests (not all developers trust to external
services to deploy applications). To run them you should define [a job](https://circleci.com/docs/2.0/jobs-steps/#jobs-overview)
and add it as a step to [a workflow](https://circleci.com/docs/2.0/workflows/). There is an example of `test` workflow
for the `simple_plug_server` application:

```yaml
version: 2.1
jobs:
  test:
    docker:
      - image: elixir:1.10
        environment:
          MIX_ENV: test
    working_directory: ~/repo
    steps:
      - checkout
      - run: mix local.hex --force
      - run: mix local.rebar --force
      - run: mix deps.get
      - run: mix deps.compile
      - run: mix test
      - store_test_results:
          path: _build/test/lib/simple_plug_server
workflows:
  version: 2
  test:
    jobs:
      - test
```

It has only the one workflow `test` with the one job `test`. This job has three parts: 
* docker - where is defined a container inside which you will deploy test environment and run tests
* working_directory - name of the folder where everything is happening
* steps - the set of commands where you download code, setup dependencies and finally run tests. 
You can also [cache dependencies](https://circleci.com/docs/2.0/caching/) on this step.

We can also improve the representing of the failed tests, for it you should add a JUnit formatter for test results
(for elixir it is the hex package [JUnitFormatter](https://github.com/victorolinasc/junit-formatter)) and specify
the directory containing subdirectories of JUnit XML or Cucumber JSON test metadata files. 
More information about it and how to add support for other languages and test frameworks look [here](https://circleci.com/docs/2.0/collect-test-data/).


### Build and push containers

On the previous steps we created the ECR repository and the user that can push images, time to setup CircleCI config.

For work with images we will use the official orb for ECR [circleci/aws-ecr@6.9.1](https://circleci.com/orbs/registry/orb/circleci/aws-ecr)
It significantly simplifies building and pushing images, let's add the new step to our config file:

```yaml
version: 2.1
orbs:
  aws-ecr: circleci/aws-ecr@6.9.1
  aws-ecs: circleci/aws-ecs@1.2.0
jobs:
  test:
    docker:
      - image: elixir:1.10
        environment:
          MIX_ENV: test
    working_directory: ~/repo
    steps:
      - checkout
      - run: mix local.hex --force
      - run: mix local.rebar --force
      - run: mix deps.get
      - run: mix deps.compile
      - run: mix test
      - store_test_results:
          path: _build/test/lib/simple_plug_server
workflows:
  version: 2
  test-and-build:
    jobs:
      - test
      - aws-ecr/build-and-push-image:
          repo: "simple_plug_server"
          tag: "${CIRCLE_BRANCH}_${CIRCLE_SHA1},${CIRCLE_BRANCH}_latest"
          requires:
            - test
          filters:
            branches:
              only:
                - master
                - development
```

Briefly about the steps of this job:
* repo - the name of the repository (last part of the `815991645042.dkr.ecr.us-west-2.amazonaws.com/simple_plug_server`)
* tag - tags that we apply to the built container, for the master branch it will add two tags: 
master_02dacfb07f7c09107e2d8da9955461f025f7f443 and master_latest
* requires - there you should describe the previous necessary steps, in this example we build an image only 
if all tests pass
* filters - describe for which branches this job should execute. There are a lot of other [filters](https://circleci.com/docs/2.0/configuration-reference/#filters-1)
that you can use to customize a workflow

But before you start to run this workflow you should add the next environment variables:
* AWS_ACCESS_KEY_ID - access key for `circleci` that you obtained on [this step]()
* AWS_SECRET_ACCESS_KEY - secret key for `circleci` that you obtained on [this step]()
* AWS_REGION - region where placed your ECR instance
* AWS_ECR_ACCOUNT_URL - url of the ECR(looks like 815991645042.dkr.ecr.us-west-2.amazonaws.com)

!CircleCI ENV Settings example.png

After successful build of the development and master branches you will see something like there: 



Great! You automatized process of running tests and building images in the next charter you will see how to
setup servers on the AWS infrastructure and redeploy them after successfully passed tests.



# Setup and update servers

After all previous steps you've got the images that's stored inside the ECR and the script that automatically build
them. In this part of the tutorial we will: 
* setup ecs clusters for development and production environments;
* add deployment commands to the CircleCI scripts.

Let's do it!

## Initialize ECS cluster

Creating of cluster consists of three steps:
1. Create an empty cluster with a VPC
2. Define the task that will launch the selected container
3. Add service that will launch and maintain desired count of ec2 instances with the previously defined task

### Create cluster
Let's start with the definition of [cluster](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/clusters.html): 

> An Amazon ECS cluster is a logical grouping of tasks or services. 

Roughly saying, clusters define scope and set of rules for the launched tasks. Creating of them is very simple:

1. Select EC2 Linux + Networking you need two clusters one for development and one for master branches
2. Select 1 On Demand t2.micro instance(or other type of ec2 instances), other configurations by default
3. For the networking section I recommend to stay the parameters by default too. It will create a new VPC with
[security group](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-security-groups.html) allowing income traffic
to the 80 PORT.

Yes that's all, you should create one for the development and one for the production. 

### Define task

1. Select EC2 launch type compatibility
2. Choose the name for the task definition(or family like sometimes it's called)
3. For the as the task role choose the role with the `AmazonECSTaskExecutionRolePolicy` policy that we  previously created 
4. Select the memory limit for example 128 MB if you server is not going to handle a lot of complex requests
5. And finally add container, on this tab we are interested in the following fields
   * Standard -> Image - initial image for the task should be copied from the ECR looks like 845992245040.dkr.ecr.us-west-2.amazonaws.com/simple_plug_server:master_latest
   * Standard -> Port mappings - associate host 80 with the port which is using the our application and will be defined nex
   * Advanced container configuration -> ENVIRONMENT -> Environment variables - define the variable with the name `PORT` and 
   desired value for example - 4100. This value must be used in the port mapping as the container port
   
Great you've created the first revision of the task definition. Of course these tasks can be launched right inside 
cluster, but we will use services to simplify updating tasks revisions. Let's add them. 

### Add service

To create a service just click on the `Create` button on the `Services` and fill the form:
1. Select EC2 in the Launch type selector, because we are deploying our tasks on EC2 instances
2. In the `Task Definition` select the task and revision that you are created earlier
3. In the `Cluster` select the cluster where you want to define a service. When you are creating service from a cluster
this field will be already selected
4. Service type - REPLICA
5. Number of tasks - 1 because we do not care about scaling for now.
6. Other setting set by default

Great! After all manipulations you've got two EC2 instances with running applications. They are available 
by Public DNS or IP.

Now let's go to the final part of this tutorial.
 
## Add deployment scripts

With an official orb [aws-ecs](https://circleci.com/orbs/registry/orb/circleci/aws-ecs) you can make this very simple. 
First of all you should add a couple of additional environment variables
We already added all necessary environment variables in the second part of this tutorial so you should only modify the
circleci config. 

```yaml

```
