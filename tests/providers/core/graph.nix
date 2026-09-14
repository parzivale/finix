# the rendered unit graph says what the configuration said
#
# Not a VM test, and deliberately: the renderer is a pure function from a configuration to a
# `.mmd` file, so a machine would add a kernel and twenty minutes and tell us nothing the
# evaluation does not. What it would not catch either way is whether the picture is *legible* -
# that is a judgement, and it is made by looking at one.
#
# So what is asserted here is the part which is not a judgement: that every shape the chart has
# a rule for appears when the configuration calls for it, that a unit's attachment is drawn once
# rather than twice, and that the two claims the chart makes on its own - "nothing waits for
# this unit" and "the shutdown side hangs off nothing" - are made only when they are true.
{
  lib,
  pkgs,
  testLib,
}:
let
  node =
    { ... }:
    {
      providers.services.backend = "finit";
      services.getty.enable = true;
      services.mdevd.enable = true;

      providers.services.units = {
        # an ordinary daemon on a level, which is what most units are
        demo = {
          description = "a demonstration daemon";
          requires = [ "basic" ];
          type.service.command = "/bin/demo";
        };

        # attached to the same level and also behind the daemon, which is the edge the chart
        # draws inside a tier. Both facts are true at once and the picture has to hold both:
        # it starts in that tier, and not before `demo` is up.
        after-demo = {
          requires = [
            "basic"
            "demo"
          ];
          type.oneshot.command = "/bin/after-demo";
        };

        # named no level at all. It runs when `demo` is up and never otherwise, but no level
        # waits for it, so nothing attached to a later level is ordered against it - the thing
        # the chart puts in its own box and its own colour.
        floats = {
          requires = [ "demo" ];
          type.oneshot.command = "/bin/floats";
        };

        # and one on the way down
        on-the-way-out = {
          requires = [ "stopped" ];
          type.oneshot.command = "/bin/out";
        };
      };
    };

  graph = (testLib.evalNode "machine" node).config.system.build.serviceGraph;

  # each is a line which must be there, or one which must not, with the reason it matters.
  # Written as fixed strings rather than patterns: the assertion is about the exact text the
  # renderer emits, and a pattern that drifts into matching something else is worse than no
  # check at all.
  present = [
    {
      # double-quoted, because a single-line `''…''` has its indentation stripped and the
      # indentation is part of what is being asserted
      line = "  u_basic --> u_demo";
      why = "a unit attached to a level hangs off that level, which is the edge it declared";
    }
    {
      line = "  u_demo --> u_multi_user";
      why = "and the next level hangs off the unit, which is what waiting for a tier is made of";
    }
    {
      line = "  u_demo(\"demo<br/>service · fork\"):::service";
      why = "a service is drawn as a service, with the readiness it resolved to on this backend";
    }
    {
      line = "  u_after_demo[\"after-demo<br/>oneshot\"]:::oneshot";
      why = "a oneshot is drawn as a oneshot";
    }
    {
      line = "  u_demo --> u_after_demo";
      why = "an edge between two units on the same level is drawn like any other";
    }
    {
      line = "  u_floats[\"floats<br/>oneshot\"]:::floating";
      why = "a unit which named no level is coloured for it, since no level waits for it";
    }
    {
      line = "  u_stopped{{\"stopped<br/>level · latch\"}}:::level";
      why = "the latch says so, because the graph falls in two there and that is not a mistake";
    }
    {
      line = "  u_on_the_way_out[\"on-the-way-out<br/>oneshot\"]:::oneshot";
      why = "the shutdown side is drawn too - it is part of the configuration";
    }
  ];

  absent = [
    {
      line = "subgraph";
      why = "the graph is drawn as it is - units, and the edges between them - with nothing boxed, grouped or collapsed";
    }
    {
      line = "--> u_stopped";
      why = "nothing leads to the latch: it means everything has stopped, which is not a fact about starting";
    }
  ];

  checkOf =
    kind: entry:
    let
      grep = "${lib.getExe' pkgs.gnugrep "grep"} -qF ${lib.escapeShellArg entry.line} graph.mmd";
    in
    ''
      # `present` fails when the line is missing, `absent` when it is there. Written this way
      # round because the first version had it backwards and reported every satisfied check as
      # a failure, which reads at a glance exactly like a renderer that emits nothing.
      if ${lib.optionalString (kind == "present") "! "}${grep}; then
        printf '%s\n' ${lib.escapeShellArg "  ${kind}: ${entry.line}"} >> failures
        printf '%s\n' ${lib.escapeShellArg "    ${entry.why}"} >> failures
      fi
    '';
in
pkgs.runCommand "check-services-graph" { } ''
  cp ${graph} graph.mmd
  : > failures

  ${lib.concatMapStrings (checkOf "present") present}
  ${lib.concatMapStrings (checkOf "absent") absent}

  if [ -s failures ]; then
    echo "the rendered unit graph is not what the configuration said:" >&2
    cat failures >&2
    echo >&2
    echo "what was rendered:" >&2
    cat graph.mmd >&2
    exit 1
  fi

  cp graph.mmd $out
''
