FROM openwhisk/dockerskeleton

ENV FLASK_PROXY_PORT 8080

RUN mkdir -p /usr/share/doc/R/html && apk add --no-cache \
    libc-dev \
    R-dev R

RUN R -e "options(repos = \
        list(CRAN = 'http://cran.us.r-project.org')); \
        install.packages('jsonlite')"

CMD ["/bin/bash", "-c", "cd actionProxy && python -u actionproxy.py"]