%% mob_nif.erl — Erlang wrapper for the static mob_nif NIF.
%% ERL_NIF_INIT(mob_nif,...) in mob_nif.c registers the NIF functions under
%% this module name. The on_load hook wires up the static linkage.
-module(mob_nif).
-export([platform/0,
         log/1,
         create_column/0, create_row/0, create_label/1, create_button/1,
         create_scroll/0, add_child/2, remove_child/1, set_text/2,
         set_text_size/2, set_text_color/2, set_background_color/2,
         set_padding/2, on_tap/2, set_root/1]).
-nifs([platform/0,
       log/1,
       create_column/0, create_row/0, create_label/1, create_button/1,
       create_scroll/0, add_child/2, remove_child/1, set_text/2,
       set_text_size/2, set_text_color/2, set_background_color/2,
       set_padding/2, on_tap/2, set_root/1]).
-on_load(init/0).

init() -> erlang:load_nif("mob_nif", 0).

platform()              -> erlang:nif_error(not_loaded).
log(_Msg)               -> erlang:nif_error(not_loaded).
create_column()             -> erlang:nif_error(not_loaded).
create_row()                -> erlang:nif_error(not_loaded).
create_label(_Text)         -> erlang:nif_error(not_loaded).
create_button(_Text)        -> erlang:nif_error(not_loaded).
create_scroll()             -> erlang:nif_error(not_loaded).
add_child(_Parent, _Child)  -> erlang:nif_error(not_loaded).
remove_child(_Child)        -> erlang:nif_error(not_loaded).
set_text(_View, _Text)      -> erlang:nif_error(not_loaded).
set_text_size(_View, _SP)   -> erlang:nif_error(not_loaded).
set_text_color(_View, _C)   -> erlang:nif_error(not_loaded).
set_background_color(_V, _C)-> erlang:nif_error(not_loaded).
set_padding(_View, _DP)     -> erlang:nif_error(not_loaded).
on_tap(_View, _Pid)         -> erlang:nif_error(not_loaded).
set_root(_View)             -> erlang:nif_error(not_loaded).
