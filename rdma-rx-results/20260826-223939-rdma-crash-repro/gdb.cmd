set pagination off
set debuginfod enabled off
handle SIGPIPE nostop noprint pass
handle SIGUSR2 nostop noprint pass
break _serverAssert
commands
silent
printf "\n===== ASSERT HIT =====\n"
bt 40
printf "\n===== assert args =====\n"
info args
printf "\n===== clients_to_close =====\n"
print server.clients_to_close->len
continue
end
run
