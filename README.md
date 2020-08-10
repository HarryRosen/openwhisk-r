# Supporting R with IBM Cloud Functions & OpenWhisk

This is a quick exploration into how to support scripts written in R within _IBM Cloud Functions_ ("Functions").

## Sample Script & IBM Cloud Functions Basics

Out of the box Functions support _Python, Javascript, go, ruby, PHP, .NET CLR, and Java_. In addition, Functions can support any arbitrary executable whether that be a bash script, C/C++ binary, Rust, or any other language. Finally, if this isn't enough Function actions can be executed from a docker container image that follows a few simple rules.

I won't go into the _action proxy_ protocol (or the new, MUCH faster and scalable version -- the _action loop_ protocol) in this document. For this set of experiments I am going to focus on using the "old" **dockerskeleton** approach to allow an arbitrary R runtime environment within an action.

Our sample R script will flip a coin 100 times and return the frequency of heads and tails. It'll also each back any passed parameters to the function action. Here's the code:

```R
#!/usr/local/bin/Rscript
library('jsonlite')
args <- commandArgs(trailingOnly = TRUE)

n <- 100
coin <- c('heads', 'tails')
flips <- sample(coin, size=n, replace=TRUE)
freq <- table(flips)
dt <- as.data.frame(freq)

cat('{"payload": ', toJSON(args), ', "response": ', toJSON(split(dt$Freq, dt$flips)), '}')
```

A couple of important points:

- Everything we will do here is from the command line using the `ibmcloud` CLI. The Functions UI doesn't support docker based actions.
- You **MUST** return a JSON dictionary from your action. Also, all parameters are passed into the action as a single JSON string on the command line.
- I don't know R :)
- I don't like R's handling of JSON data and for some reason parameters from the command line come over as escaped. Given I don't know R or how to really use _jsonlite_ this wasn't worth fixing for this example.
- For reasons that'll become clear later I include a hash bang to the location of _Rscript_. Depending on the Docker container image you build this may be in _/usr/bin_ or _/usr/local/bin_.
- Your main R script should be executable (`chmod +x flip.R` for example) since it'll be run as a bash script in this setup based on the hashbang.

## Method 1 - Extending _dockerskeleton_

The default docker container image for Functions runs the script _/action/exec_ in the container when invoked.
Let's create an empty action using the _dockerskeleton_ image.

```bash
~/dev/openwhisk-r$ ibmcloud fn action create flip --docker openwhisk/dockerskeleton
ok: created action flip

~/dev/openwhisk-r$ ibmcloud fn action invoke flip --blocking --result
{
    "error": "This is a stub action. Replace it with custom logic."
}
```

If you go and look you'll learn that the _dockerskeleton_ image is a bare bones Alpine linux image with a minimal version of python3. A python Flask web app _actionproxy.py_ handles the initialization and running of any script file it is sent. So out of the box _dockerskeleton_ is perfect for bash scripts, binaries, and the simplest of Python scripts -- but not R.
 
So our first approach is to create our own Docker image based on _dockerfile_ and in it load R and any libraries needed. 

```Dockerfile
FROM openwhisk/dockerskeleton

ENV FLASK_PROXY_PORT 8080

RUN mkdir -p /usr/share/doc/R/html && apk add --no-cache \
    libc-dev \
    R-dev R

RUN R -e "options(repos = \
        list(CRAN = 'http://cran.us.r-project.org')); \
        install.packages('jsonlite')"

CMD ["/bin/bash", "-c", "cd actionProxy && python -u actionproxy.py"]
```

There's no magic here. I learned which packages to install for _jsonlite_ by experiementing a little with the `apk` package manager for Apline linux and I kept the Python based `actionproxy.py` file. So this Dockerfile is based on the default skeleton and loads R and associated R packages and libraries.

```bash
~/dev/openwhisk-r$ docker build -t rskeleton .
Sending build context to Docker daemon  24.06kB
Step 1/5 : FROM openwhisk/dockerskeleton
 ---> b35ea25a189d
Step 2/5 : ENV FLASK_PROXY_PORT 8080
 ---> Using cache
 ---> 50a5d6c32a44
Step 3/5 : RUN mkdir -p /usr/share/doc/R/html && apk add --no-cache     libc-dev     R-dev R
 ---> Using cache
 ---> 37d05c9aeb83
Step 4/5 : RUN R -e "options(repos =         list(CRAN = 'http://cran.us.r-project.org'));         install.packages('jsonlite')"
 ---> Using cache
 ---> 3b02c37c0baf
Step 5/5 : CMD ["/bin/bash", "-c", "cd actionProxy && python -u actionproxy.py"]
 ---> Using cache
 ---> ca7d0c08ddfa
Successfully built ca7d0c08ddfa
Successfully tagged rskeleton:latest
~/dev/openwhisk-r$ docker tag rskeleton davetropeano/rskeleton:0.1
~/dev/openwhisk-r$ docker push davetropeano/rskeleton:0.1
The push refers to repository [docker.io/davetropeano/rskeleton]
5cc7f7f3e5e9: Pushed 
27de3eedb1d3: Pushed 
d85c68a0ba08: Pushed 
71575fe22aa1: Pushed 
7c8edcf0a5fc: Pushed 
d39b94215d6b: Pushed 
be78a772120f: Pushed 
9800e3c5b8b7: Mounted from openwhisk/dockerskeleton 
1f7c82fa2a03: Mounted from openwhisk/dockerskeleton 
a67dc90aedcd: Pushed 
23832706ff75: Mounted from openwhisk/dockerskeleton 
61b675163d2a: Mounted from openwhisk/dockerskeleton 
5216338b40a7: Mounted from openwhisk/dockerskeleton 
0.1: digest: sha256:725e14a5eca8bd7bd12a0f2873ead7a2b40476cd37b266e2467dfecbb7c86c91 size: 3041

~/dev/openwhisk-r$ ic fn action update flip flip.R --docker davetropeano/rskeleton:0.1
ok: updated action flip

~/dev/openwhisk-r$ ibmcloud fn action invoke flip --blocking --result --param name Dave
{
    "payload": [
        "{\"name\": \"Dave\"}"
    ],
    "response": {
        "heads": [
            51
        ],
        "tails": [
            49
        ]
    }
}
```

**NOTE** Alpine Linux installs `Rscript` in _/usr/bin_ so I had to change the first line of `flip.R`.

OK, so I built a custom Docker image and used it to update the `flip` action. Notice that with the update I passed in the `flip.R` file and used the new docker image. When I invoked the function I passed it a parameter. This will work now with any arbitrary R script as long as the container image is able to pull the needed R libraries.

## Method 2 - Using Rocker

Again, I am not an R developer... in surfing the 'net to learn the bare minimum of R needed I came across the [Rocker Project](https://www.rocker-project.org/) -- standard Docker images for various R environments. Thinking that perhaps you didn't want to create your own R distros and would want to use community standards I thought it made sense to create a _rocker-skeleton_ image. In this example we'll use the _rocker:tidyverse_ image because _tidyverse_ seems to be popular within the community (but again, what do I know?).

Here's my "Rockerfile":

```Dockerfile
FROM rocker/tidyverse

ENV FLASK_PROXY_PORT 8080

# since we are using an R base docker image we need to install the missing python
# pieces to run the actionProxy
RUN mkdir -p /actionProxy && mkdir -p /action && \
    apt-get update --fix-missing && apt-get install -y ca-certificates libglib2.0-0 libxext6 libsm6 libxrender1 libxml2-dev && \
    apt-get install -y python3-pip python3-dev && pip3 install gevent flask

COPY exec.default /action/exec
COPY actionproxy.py /actionProxy

CMD ["/bin/bash", "-c", "cd actionProxy && python3 -u actionproxy.py"]
```

The rocker images are based on Debian Linux. Out of the box they include python3 but do not include the module `pip` which is the python package managed. Since I didn't want to think about how to install Flask (needed for the `actionproxy.py` file OpenWhisk uses) I took the shortest route and just added the extra python stuff needed to load pip and the Flask framework.

```bash
~/dev/openwhisk-r$ docker build -t openwhisk-rocker -f Rockerfile .
Sending build context to Docker daemon  24.06kB
Step 1/6 : FROM rocker/tidyverse
 ---> 0d0d7e3baa35
Step 2/6 : ENV FLASK_PROXY_PORT 8080
 ---> Using cache
 ---> 439b263df44c
Step 3/6 : RUN mkdir -p /actionProxy && mkdir -p /action &&     apt-get update --fix-missing && apt-get install -y ca-certificates libglib2.0-0 libxext6 libsm6 libxrender1 libxml2-dev &&     apt-get install -y python3-pip python3-dev && pip3 install gevent flask
 ---> Using cache
 ---> dd9f4637092a
Step 4/6 : COPY exec.default /action/exec
 ---> Using cache
 ---> 103fe19a91f8
Step 5/6 : COPY actionproxy.py /actionProxy
 ---> Using cache
 ---> 3b652412f417
Step 6/6 : CMD ["/bin/bash", "-c", "cd actionProxy && python3 -u actionproxy.py"]
 ---> Using cache
 ---> 2ec37e26cf2a
Successfully built 2ec37e26cf2a
Successfully tagged openwhisk-rocker:latest

~/dev/openwhisk-r$ docker tag openwhisk-rocker davetropeano/openwhisk-rocker:0.1

~/dev/openwhisk-r$ docker push davetropeano/openwhisk-rocker:0.1
The push refers to repository [docker.io/davetropeano/openwhisk-rocker]
cacf23ac149a: Pushed 
3a6dfcb79111: Pushed 
32d9289debf1: Pushed 
305869847ed8: Mounted from rocker/tidyverse 
65338083bd3c: Mounted from rocker/tidyverse 
375fcfc77045: Mounted from rocker/tidyverse 
fb15b6f503e1: Mounted from rocker/tidyverse 
fa31745bc575: Pushed 
05f3b67ed530: Pushed 
ec1817c93e7c: Pushed 
9e97312b63ff: Mounted from rocker/tidyverse 
e1c75a5e0bfa: Mounted from rocker/tidyverse 
0.1: digest: sha256:c4b4fba5627629f7bb171cf52f262bf43e80f706f0429e9250cdb7af766596d3 size: 2837
```

**NOTE:** with the rocker images `Rscript` is in `/usr/local/bin/Rscript`. So I changed the `flip.R` sample back :)

OK. So with the new container image loaded onto Docker Hub we can update our action. In addition to modifying the location of `Rscript` in the hashbang I also changed the list `c('heads', 'tails')` to `c('a', 'b')` just to make sure I was running something different.

```bash
~/dev/openwhisk-r$ ibmcloud fn action update flip flip.R --docker davetropeano/openwhisk-rocker:0.1
ok: updated action flip

~/dev/openwhisk-r$ ibmcloud fn action invoke flip --blocking --result --param name Dave
{
    "payload": [
        "{\"name\": \"Dave\"}"
    ],
    "response": {
        "a": [
            56
        ],
        "b": [
            44
        ]
    }
}
```

### Supporting Multiple Files

When you create or update an action in Functions you can provide either:

- Just a Docker image. This assumes that your action source code is already in the image in the `/action` directory and the entrypoint to your action is the executable `exec`. 
- A source file (and optional Docker image). If you provide a single source file Functions writes this to `/action/exec` in the container and executes that `exec` script.
- A zip file (and optional Docker image) with an executable `exec` at the top level of zip archive.

You use zip files to include workspaces and multiple source files. In order to execute your R scripts we need to establish a convention. Without knowing any better here is the convention I came up with:

- The "main" (top level) R script is named `main.r`.
- The zipfile contains an executable script named `exec`

I included an `exec` script in this repo that just does a `source('main.r')` to boostrap things:

```R
#!/usr/local/bin/Rscript
source('main.r')
```

This mechanism is similar to how Python and NodeJS is supported in Functions and should work with virtual environments at least how I understand they can work in R.

`zip myaction.zip exec main.r` (and whatever other files/directories you needed in the zip)

`ibmcloud fn action update flip myaction.zip --docker davetropeano/openwhisk-rocker:0.1`

### Conclusion

Hopefully this is enough to get you going with using R for your Functions actions. If you want to optimize the execution of R scripts as actions I suggest using the newer `actionLoop` method documented here: [https://github.com/apache/openwhisk/blob/master/docs/actions-actionloop.md](https://github.com/apache/openwhisk/blob/master/docs/actions-actionloop.md).

