#ifndef SNAKEH
#define SNAKEH

typedef enum {NW,N,NE,W,E,SW,S,SE} direction;
#define NUMDIRS 8

typedef struct point_t {
  int x;
  int y;
} sn_point;

typedef struct snake_st {
  direction       dir;
  int             len;
  int             color;        /* color pair to use if colored snakes */
  sn_point        *body;
  int             pid;       /* useful for playing with scheduling */
  struct snake_st *others;      /* a utility link to find all snakes again */
} *snake;

/* Colors range from 1 (blue on black) to 8 ( black on black).
 */
#define MAX_VISIBLE_SNAKE 7

extern int          start_windowing();
extern void         end_windowing();
extern snake        new_snake(int y, int x, int len, int dir, int color) ;
extern void         free_snake(snake s);
extern void         draw_all_snakes();
extern void         run_snake(void *s);
extern void         run_hungry_snake(void *s);
extern void         kill_snake();
extern int          snakes_running();
extern unsigned int get_snake_delay();
extern void         set_snake_delay(unsigned int msec);
extern snake        snakeFromLWpid(int lw_pid);
extern void setup_snakes(int);


// Structs
typedef struct {
    unsigned long pid;
} Proccess;

// Function declarations
#ifdef __cplusplus
extern "C" {
#endif

extern void kfree(void *addr);
extern void *kmalloc(unsigned long size);
extern void yield(void);
extern void VGA_clear(void);
extern unsigned int VGA_row_count(void);
extern unsigned int VGA_col_count(void);
extern void kexit(void);
extern void VGA_display_attr_char(int x, int y, char c, unsigned int fg, unsigned int bg);
extern int PROC_create_kthread(void (*entry_point)(void *), void *arg);
extern unsigned long PROC_get_current_pid(void);

#ifdef __cplusplus
}
#endif


#endif
