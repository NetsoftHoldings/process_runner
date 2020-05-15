#!/bin/sh

tag=`git describe --tags --exact-match  HEAD 2> /dev/null`

if [ $? -eq 0 ]; then
  version=`grep VERSION lib/process_balancer/version.rb | sed -e "s/.*'\([^']*\)'.*/\1/"`
  
  if [ "v$version" = "$tag" ]; then
    echo "Revision $tag Matches $version"
  else
    echo "Revision $tag does not match $version"
    exit 2
  fi
else
  echo "No tag found"
  exit 1
fi
