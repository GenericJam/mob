%% mob_nif.erl — Erlang wrapper for the static mob_nif NIF (Compose backend).
%% ERL_NIF_INIT(mob_nif,...) in mob_nif.c registers the NIF functions under
%% this module name. The on_load hook wires up the static linkage.
-module(mob_nif).
-export([platform/0,
         log/1, log/2,
         set_transition/1,
         set_root/1,
         register_tap/1,
         clear_taps/0]).
-nifs([platform/0,
       log/1, log/2,
       set_transition/1,
       set_root/1,
       register_tap/1,
       clear_taps/0]).
-on_load(init/0).

init() -> erlang:load_nif("mob_nif", 0).

platform()               -> erlang:nif_error(not_loaded).
log(_Msg)                -> erlang:nif_error(not_loaded).
log(_Level, _Msg)        -> erlang:nif_error(not_loaded).
set_transition(_Trans)   -> erlang:nif_error(not_loaded).
set_root(_Json)          -> erlang:nif_error(not_loaded).
register_tap(_Pid)       -> erlang:nif_error(not_loaded).
clear_taps()             -> erlang:nif_error(not_loaded).
