# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
#
# This file is part of VirtualFlow.
#
# VirtualFlow is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# VirtualFlow is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with VirtualFlow.  If not, see <https://www.gnu.org/licenses/>.

FROM amazonlinux:2 as vflpbuild
RUN yum -y install java-11-amazon-corretto-headless

ARG CX_LICENSE_FILE

ADD templates /opt/vf/tools/templates

ADD packages/jchemsuite.tar.gz /opt/vf/packages
ADD packages/nailgun.tar.gz /opt/vf/packages
ADD helper /opt/vf/helper

WORKDIR /opt/vf/helper/vf
RUN javac -cp "/opt/vf/packages/jchemsuite/lib/*" CxCalcAttr.java
WORKDIR /opt/vf/helper
RUN jar cf CxCalcAttr.jar vf

COPY $CX_LICENSE_FILE /opt/vf/packages/chemaxon/license.cxl



FROM amazonlinux:2

RUN amazon-linux-extras install epel -y
RUN yum update -y && yum -y install python3 openbabel java-11-amazon-corretto-headless which iproute
RUN pip3 install boto3 rdkit

COPY --from=vflpbuild /opt/vf /opt/vf
ADD *.py *.sh /opt/vf/tools/
RUN chmod +x -R /opt/vf/tools/*.sh \
        /opt/vf/tools/*.py  \
        /opt/vf/tools/templates/*.sh \
        /opt/vf/packages/nailgun/nailgun-client/target/ng

ENV USER ec2-user

WORKDIR /

ENTRYPOINT ["/opt/vf/tools/templates/template1.awsbatch.sh"]
