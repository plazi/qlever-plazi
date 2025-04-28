FROM buildpack-deps:buster-curl AS build-stage 

RUN apt-get update
RUN DEBIAN_FRONTEND=noninteractive apt install -y git jq

# Add shell script and grant execution rights
ADD prepare-rdf.sh /prepare-rdf.sh
RUN chmod +x /prepare-rdf.sh

RUN mkdir -p /workspace

RUN /prepare-rdf.sh && echo "Cache busted at $(date)"

FROM adfreiburg/qlever AS runtime-image

WORKDIR /qlever

COPY --from=build-stage /workspace/plazi-treatments.nq /qlever/treatments.nq
COPY --from=build-stage /workspace/col.nt /qlever/col.nt
ADD Qleverfile /qlever/Qleverfile

RUN qlever index

ENTRYPOINT [ "qlever" ]
CMD [ "start", "--description", "Plazi Treatments", "--run-in-foreground" ]

