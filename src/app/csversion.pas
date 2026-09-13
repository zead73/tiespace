unit CsVersion;

(* The client version string, injected from the git tag at release time.

   version.inc is a one-line Pascal string literal. In the repo it is 'dev'; the
   release workflow overwrites it with the tag (e.g. 'v0.5') before the build, so
   a released binary reports its version while a plain local build says 'dev'. *)

{$mode objfpc}{$H+}

interface

const
  AppVersion = {$I version.inc};

implementation

end.
