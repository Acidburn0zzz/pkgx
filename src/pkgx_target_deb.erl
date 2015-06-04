-module(pkgx_target_deb).

-export([run/2]).

run(Vars, Target) ->
    PackageName = proplists:get_value(package_name, Vars),
    Version = proplists:get_value(version, Vars),

    DebFiles = filelib:wildcard(PackageName ++ "_" ++ Version ++ "-*.{deb,changes,build}", Target),
    case length(DebFiles) == 3 of
        true ->
            io:format(user, "Skipping ~p, version ~p is already packaged~n", [PackageName, Version]),
            {ok, Vars};
        false ->
            io:format(user, "Building ~p, version ~p. Output: ~p~n", [PackageName, Version, Target]),
            make_package(Vars, Target)
    end.

make_package(Vars, Target) ->
    Basedir = proplists:get_value(basedir, Vars),

    % Always start with a fresh debian dir
    ec_file:remove(Basedir ++ "/debian", [recursive]),

    InstallPrefix = proplists:get_value(install_prefix, Vars),
    InstallDir = proplists:get_value(install_dir_name, Vars),

    % Because these need to be scanned by the install files step
    ExtraTemplates = proplists:get_value(extra_templates, Vars, []),
    process_templates(ExtraTemplates, Basedir, Vars),

    {ok, DirList} = file:list_dir(Basedir),
    InstallList = [ X || X <- DirList, X /= "debian" ],
    Install = lists:map(
        fun(A) ->
            To = InstallPrefix ++ "/" ++ InstallDir,
            case filelib:is_file(Basedir ++ "/" ++ A) of
                true ->
                    {A, To};
                false ->
                    {A ++ "/", To}
            end
        end,
        InstallList
    ),

    ExtraFiles = proplists:get_value(extra_files, Vars, []),
    
    OverrideFiles = proplists:get_value(override_files, Vars, []),
    InstallFiles = case length(OverrideFiles) > 0 of
        true ->
            OverrideFiles;
        false ->
            Install ++ ExtraFiles
    end,
    PkgVars = [ {install, InstallFiles} | Vars ],

    PkgName = proplists:get_value(package_name, PkgVars),
    Templates =
        [
         {"debian/changelog", deb_debian_changelog_dtl},
         {"debian/control", deb_debian_control_dtl},
         {"debian/rules", deb_debian_rules_dtl},
         {"debian/compat", <<"7">>},
         {"debian/" ++ PkgName ++ ".install", deb_debian_install_dtl}
        ],
    process_templates(Templates, Basedir, PkgVars),

    CommandResult = command("debuild --no-tgz-check --no-lintian -i -us -uc -b", Basedir),
    case CommandResult of
        {0, _} ->
            Parent = filename:absname(filename:dirname(Basedir)),
            movefiles(filelib:wildcard(Parent ++ "/*.{deb,build,changes}"), Target),
            {ok, Vars};
        {ExitCode, Error} ->
            io:format(standard_error, "Failed to build package:~n~s", [Error]),
            {error, [{exitcode, ExitCode},
                     {error, Error},
                     {vars, Vars},
                     {target, Target}]}
    end.


process_templates(Templates, Basedir, Vars) ->
    lists:map(fun   ({F, V}) ->
                        TargetFile = filename:join(Basedir, F),
                        filelib:ensure_dir(TargetFile),
                        process_file_entry(TargetFile, V, Vars);
                    ({F, V, M}) when is_integer(M) ->
                        TargetFile = filename:join(Basedir, F),
                        filelib:ensure_dir(TargetFile),
                        process_file_entry(TargetFile, V, Vars),
                        file:change_mode(TargetFile, M)
              end,
              Templates).


movefiles([FilePath|Files], To) ->
    FileName = lists:last(filename:split(FilePath)),
    ec_file:move(FilePath, To ++ FileName),
    movefiles(Files, To);
movefiles([], _To) ->
    ok.

process_file_entry(File, Module, Vars) when is_atom(Module) ->
    {ok, Output} = Module:render(Vars),
    process_file_entry(File, iolist_to_binary(Output), Vars);
process_file_entry(File, Output, _Vars) when is_binary(Output) ->
    ok = file:write_file(File, Output).

command(Cmd, Dir) ->
    command(Cmd, Dir, []).
command(Cmd, Dir, Env) ->
    CD = if Dir =:= "" -> [];
        true -> [{cd, Dir}]
     end,
    SetEnv = if Env =:= [] -> []; 
        true -> [{env, Env}]
         end,
    Opt = CD ++ SetEnv ++ [stream, exit_status, use_stdio,
               stderr_to_stdout, in, eof],
    P = open_port({spawn, Cmd}, Opt),
    get_data(P, []).

get_data(P, D) ->
    receive
    {P, {data, D1}} ->
        get_data(P, [D1|D]);
    {P, eof} ->
        port_close(P),    
        receive
        {P, {exit_status, N}} ->
            {N, normalize(lists:flatten(lists:reverse(D)))}
        end
    end.

normalize([$\r, $\n | Cs]) ->
    [$\n | normalize(Cs)];
normalize([$\r | Cs]) ->
    [$\n | normalize(Cs)];
normalize([C | Cs]) ->
    [C | normalize(Cs)];
normalize([]) ->
    [].
