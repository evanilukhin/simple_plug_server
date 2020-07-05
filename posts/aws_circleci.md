# Preparation
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

# AWS

This chapter is about setting up the AWS environment. At the end of it you will have completely deployed application.
Let's start. Almost all steps will be inside the [Amazon Container Services](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/Welcome.html)
space.

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

Let's build our images that we made for development and master. For this step you should have installed 
[AWS Command Line Interface](https://docs.aws.amazon.com/cli/latest/userguide/cli-chap-welcome.html) 
how to it, see [Installing the AWS CLI version 2](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html). 



### Setup network

### Initialize ECS cluster


# CircleCI
