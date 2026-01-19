//
//  subprocess.h
//  Protein Window Manager
//

#ifndef subprocess_h
#define subprocess_h

#ifdef __cplusplus
extern "C" {
#endif

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include <sys/types.h>

typedef struct subprocess {
    int pid;
    int stdin_fd;
    int stdout_fd;
    int stderr_fd;
    bool is_running;
} subprocess_t;

// Execute a command and return subprocess handle
subprocess_t *subprocess_execute(const char *command, const char **argv, const char *working_dir);

// Execute a command as a specific user and return subprocess handle
subprocess_t *subprocess_execute_as_user(const char *command, const char **argv, const char *working_dir, const char *username);

// Wait for subprocess to complete and return exit code
int subprocess_wait(subprocess_t *process);

// Terminate a subprocess
bool subprocess_terminate(subprocess_t *process);

// Check if subprocess is still running
bool subprocess_is_running(subprocess_t *process);

// Read output from subprocess stdout
ssize_t subprocess_read_stdout(subprocess_t *process, char *buffer, size_t size);

// Read output from subprocess stderr
ssize_t subprocess_read_stderr(subprocess_t *process, char *buffer, size_t size);

// Write to subprocess stdin
ssize_t subprocess_write_stdin(subprocess_t *process, const char *data, size_t size);

// Close subprocess handles and free memory
void subprocess_cleanup(subprocess_t *process);

#ifdef __cplusplus
}
#endif

#endif /* subprocess_h */