FROM buildpack-deps:buster-curl AS build-stage 

# Install raptor
RUN apt-get update
RUN DEBIAN_FRONTEND=noninteractive apt install -y git raptor2-utils

# Add shell script and grant execution rights
ADD prepare-rdf.sh /prepare-rdf.sh
RUN chmod +x /prepare-rdf.sh

RUN mkdir -p /workspace

RUN chmod +x /prepare-rdf.sh

RUN /prepare-rdf.sh

FROM adfreiburg/qlever AS runtime-image

RUN mkdir -p /qlever
WORKDIR /qlever

COPY --from=build-stage /workspace/treatments.nt /qlever/treatments.nt
ADD Qleverfile /qlever/Qleverfile

RUN qlever index

CMD [ "qlever", "start" ]

