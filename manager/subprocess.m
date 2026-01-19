//
//  subprocess.m
//  Protein Window Manager
//

#import <Foundation/Foundation.h>
#include "subprocess.h"
#include <unistd.h>
#include <sys/wait.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <signal.h>

subprocess_t *subprocess_execute(const char *command, const char **argv, const char *working_dir) {
    subprocess_t *process = malloc(sizeof(subprocess_t));
    if (!process) return NULL;
    
    int stdin_pipe[2], stdout_pipe[2], stderr_pipe[2];
    
    if (pipe(stdin_pipe) == -1 || pipe(stdout_pipe) == -1 || pipe(stderr_pipe) == -1) {
        free(process);
        return NULL;
    }
    
    pid_t pid = fork();
    if (pid == -1) {
        close(stdin_pipe[0]); close(stdin_pipe[1]);
        close(stdout_pipe[0]); close(stdout_pipe[1]);
        close(stderr_pipe[0]); close(stderr_pipe[1]);
        free(process);
        return NULL;
    }
    
    if (pid == 0) {
        // Child process
        close(stdin_pipe[1]);
        close(stdout_pipe[0]);
        close(stderr_pipe[0]);
        
        dup2(stdin_pipe[0], STDIN_FILENO);
        dup2(stdout_pipe[1], STDOUT_FILENO);
        dup2(stderr_pipe[1], STDERR_FILENO);
        
        close(stdin_pipe[0]);
        close(stdout_pipe[1]);
        close(stderr_pipe[1]);
        
        if (working_dir && chdir(working_dir) == -1) {
            exit(127);
        }
        
        if (argv) {
            execvp(command, (char *const *)argv);
        } else {
            char *args[] = {(char *)command, NULL};
            execvp(command, args);
        }
        
        exit(127);
    }
    
    // Parent process
    close(stdin_pipe[0]);
    close(stdout_pipe[1]);
    close(stderr_pipe[1]);
    
    process->pid = pid;
    process->stdin_fd = stdin_pipe[1];
    process->stdout_fd = stdout_pipe[0];
    process->stderr_fd = stderr_pipe[0];
    process->is_running = true;
    
    return process;
}

int subprocess_wait(subprocess_t *process) {
    if (!process || !process->is_running) return -1;
    
    int status;
    waitpid(process->pid, &status, 0);
    process->is_running = false;
    
    return WEXITSTATUS(status);
}

bool subprocess_terminate(subprocess_t *process) {
    if (!process || !process->is_running) return false;
    
    if (kill(process->pid, SIGTERM) == -1) return false;
    
    int status;
    waitpid(process->pid, &status, 0);
    process->is_running = false;
    
    return true;
}

bool subprocess_is_running(subprocess_t *process) {
    if (!process) return false;
    
    if (!process->is_running) return false;
    
    int status;
    pid_t result = waitpid(process->pid, &status, WNOHANG);
    
    if (result == 0) {
        return true;
    } else if (result == -1) {
        process->is_running = false;
        return false;
    } else {
        process->is_running = false;
        return false;
    }
}

ssize_t subprocess_read_stdout(subprocess_t *process, char *buffer, size_t size) {
    if (!process || process->stdout_fd == -1) return -1;
    return read(process->stdout_fd, buffer, size);
}

ssize_t subprocess_read_stderr(subprocess_t *process, char *buffer, size_t size) {
    if (!process || process->stderr_fd == -1) return -1;
    return read(process->stderr_fd, buffer, size);
}

ssize_t subprocess_write_stdin(subprocess_t *process, const char *data, size_t size) {
    if (!process || process->stdin_fd == -1) return -1;
    return write(process->stdin_fd, data, size);
}

void subprocess_cleanup(subprocess_t *process) {
    if (!process) return;
    
    if (process->is_running) {
        subprocess_terminate(process);
    }
    
    if (process->stdin_fd != -1) close(process->stdin_fd);
    if (process->stdout_fd != -1) close(process->stdout_fd);
    if (process->stderr_fd != -1) close(process->stderr_fd);
    
    free(process);
}