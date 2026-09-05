#!/usr/bin/env python3
"""Five escalating Rust tasks. Graded by compiling the model's code with a hidden
test main() appended — pass = compiles AND all asserts hold."""
import json

COMMON = ("\n\nRules: Rust 2021, std only (no external crates). Provide ONLY the requested "
          "items in one ```rust code block. Do NOT write a main() function — the grader "
          "appends its own tests. Your code must compile with rustc as-is with a main appended.")

Q = [
 dict(id="R1", cat="rust", max_tokens=8192, grader="rust", answer="",
  prompt="RUST TASK 1 (warmup — ownership basics).\n"
   "Write `pub fn squash(v: &mut Vec<String>)` which removes CONSECUTIVE duplicate strings "
   "in place, keeping the first of each run, and also trims ASCII whitespace from both ends "
   "of every surviving string (trim AFTER dedup, based on original values for comparison)." + COMMON,
  tests=r'''
fn main() {
    let mut v: Vec<String> = vec![" a ".into(), " a ".into(), "b".into(), "b ".into(), "b".into(), " a ".into()];
    squash(&mut v);
    assert_eq!(v, vec!["a".to_string(), "b".to_string(), "b".to_string(), "b".to_string(), "a".to_string()]);
    let mut e: Vec<String> = vec![];
    squash(&mut e);
    assert!(e.is_empty());
    let mut one: Vec<String> = vec!["  x".into()];
    squash(&mut one);
    assert_eq!(one, vec!["x".to_string()]);
    println!("OK");
}'''),

 dict(id="R2", cat="rust", max_tokens=10240, grader="rust", answer="",
  prompt="RUST TASK 2 (data structure — generic LRU cache).\n"
   "Implement `pub struct Lru<K, V>` with:\n"
   "  `pub fn new(cap: usize) -> Self` (cap >= 1),\n"
   "  `pub fn put(&mut self, k: K, v: V)`,\n"
   "  `pub fn get(&mut self, k: &K) -> Option<&V>`.\n"
   "get() marks the entry most-recently-used. put() on a full cache evicts the "
   "least-recently-used entry. Reasonable bounds on K (e.g. Eq + Hash + Clone) are fine." + COMMON,
  tests=r'''
fn main() {
    let mut c: Lru<String, i32> = Lru::new(2);
    c.put("a".to_string(), 1);
    c.put("b".to_string(), 2);
    assert_eq!(c.get(&"a".to_string()), Some(&1));   // a is now MRU
    c.put("c".to_string(), 3);                        // evicts b
    assert_eq!(c.get(&"b".to_string()), None);
    assert_eq!(c.get(&"a".to_string()), Some(&1));
    assert_eq!(c.get(&"c".to_string()), Some(&3));
    c.put("a".to_string(), 10);                       // update in place
    assert_eq!(c.get(&"a".to_string()), Some(&10));
    let mut s: Lru<i32, i32> = Lru::new(1);
    s.put(1, 1); s.put(2, 2);
    assert_eq!(s.get(&1), None);
    assert_eq!(s.get(&2), Some(&2));
    println!("OK");
}'''),

 dict(id="R3", cat="rust", max_tokens=12288, grader="rust", answer="",
  prompt="RUST TASK 3 (concurrency — ordered parallel map).\n"
   "Write `pub fn parallel_map<T, R, F>(items: Vec<T>, f: F, workers: usize) -> Vec<R>`\n"
   "where `T: Send + 'static, R: Send + 'static, F: Fn(T) -> R + Send + Sync + 'static`.\n"
   "Process items across exactly `workers` OS threads (std::thread; assume workers >= 1) and "
   "return results in the ORIGINAL input order. Do not spawn one thread per item." + COMMON,
  tests=r'''
static PEAK: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
static CUR: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
fn main() {
    const SC: std::sync::atomic::Ordering = std::sync::atomic::Ordering::SeqCst;
    let items: Vec<u64> = (0..100).collect();
    let out = parallel_map(items, |x| {
        let c = CUR.fetch_add(1, SC) + 1;
        PEAK.fetch_max(c, SC);
        std::thread::sleep(std::time::Duration::from_millis(2));
        CUR.fetch_sub(1, SC);
        x * x
    }, 4);
    assert_eq!(out.len(), 100);
    for (i, v) in out.iter().enumerate() { assert_eq!(*v, (i as u64) * (i as u64)); }
    assert!(PEAK.load(SC) <= 4, "more than `workers` concurrent calls");
    let empty: Vec<u32> = vec![];
    let out2 = parallel_map(empty, |x| x, 3);
    assert!(out2.is_empty());
    println!("OK");
}'''),

 dict(id="R4", cat="rust", max_tokens=14336, grader="rust", answer="",
  prompt="RUST TASK 4 (unsafe discipline — mutable windows iterator).\n"
   "Implement `pub struct PairsMut<'a, T>` and `pub fn pairs_mut<T>(s: &mut [T]) -> PairsMut<'_, T>` "
   "where PairsMut implements `Iterator<Item = (&'a mut T, &'a mut T)>`, yielding NON-OVERLAPPING "
   "consecutive pairs: for [a,b,c,d,e] it yields (a,b) then (c,d) and drops the odd tail. "
   "You may NOT call chunks_mut / chunks_exact_mut / split_at_mut or any slice splitting helper — "
   "implement the aliasing-safe pointer arithmetic yourself with `unsafe` (this is the point of the task). "
   "The iterator must be sound: each element handed out at most once." + COMMON,
  tests=r'''
fn main() {
    let mut v = vec![1i32, 2, 3, 4, 5];
    let mut n = 0;
    for (a, b) in pairs_mut(&mut v) {
        std::mem::swap(a, b);
        *a += 10; *b += 10;
        n += 1;
    }
    assert_eq!(n, 2);
    assert_eq!(v, vec![12, 11, 14, 13, 5]);
    let mut e: Vec<u8> = vec![7];
    assert_eq!(pairs_mut(&mut e).count(), 0);
    let mut w: Vec<u8> = vec![];
    assert_eq!(pairs_mut(&mut w).count(), 0);
    // borrows returned must live as long as the iterator borrow — collect then mutate
    let mut z = vec![1u8, 2, 3, 4];
    let refs: Vec<(&mut u8, &mut u8)> = pairs_mut(&mut z).collect();
    for (a, b) in refs { *a = 9; *b = 9; }
    assert_eq!(z, vec![9, 9, 9, 9]);
    println!("OK");
}'''),

 dict(id="R5", cat="rust", max_tokens=16384, grader="rust", answer="",
  prompt="RUST TASK 5 (systems — minimal async executor).\n"
   "Using only std, implement:\n"
   "  `pub fn block_on<F: std::future::Future>(fut: F) -> F::Output` — polls the future to "
   "completion on the current thread. Build a proper Waker (RawWaker/RawWakerVTable or Arc + std::task::Wake); "
   "when the future returns Pending it must only be re-polled after wake() was called (park/unpark or "
   "a flag+spin is acceptable, but a busy loop that ignores the waker entirely is not: the grader's "
   "future wakes from ANOTHER THREAD after a delay).\n"
   "  `pub struct YieldNow { pub remaining: u32 }` implementing Future<Output = ()>: each poll with "
   "remaining > 0 decrements it, calls wake-by-ref on the context's waker, and returns Pending; a poll "
   "with remaining == 0 resolves Ready(())." + COMMON,
  tests=r'''
struct GraderThreadWake { polls: u32, armed: std::sync::Arc<std::sync::Mutex<Option<std::task::Waker>>> }
impl std::future::Future for GraderThreadWake {
    type Output = u32;
    fn poll(mut self: std::pin::Pin<&mut Self>, cx: &mut std::task::Context<'_>) -> std::task::Poll<u32> {
        self.polls += 1;
        if self.polls >= 3 { return std::task::Poll::Ready(self.polls); }
        let armed = self.armed.clone();
        *armed.lock().unwrap() = Some(cx.waker().clone());
        let a2 = armed.clone();
        std::thread::spawn(move || {
            std::thread::sleep(std::time::Duration::from_millis(30));
            if let Some(w) = a2.lock().unwrap().take() { w.wake(); }
        });
        std::task::Poll::Pending
    }
}
struct GraderCount<F>(F, std::sync::Arc<std::sync::atomic::AtomicU32>);
impl<F: std::future::Future> std::future::Future for GraderCount<F> {
    type Output = F::Output;
    fn poll(self: std::pin::Pin<&mut Self>, cx: &mut std::task::Context<'_>) -> std::task::Poll<F::Output> {
        let this = unsafe { self.get_unchecked_mut() };
        this.1.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        unsafe { std::pin::Pin::new_unchecked(&mut this.0) }.poll(cx)
    }
}
fn main() {
    let polls = std::sync::Arc::new(std::sync::atomic::AtomicU32::new(0));
    let y = GraderCount(YieldNow { remaining: 4 }, polls.clone());
    block_on(y);
    assert_eq!(polls.load(std::sync::atomic::Ordering::SeqCst), 5, "YieldNow must pend 4 times then resolve");
    let t0 = std::time::Instant::now();
    let tw = GraderThreadWake { polls: 0, armed: std::sync::Arc::new(std::sync::Mutex::new(None)) };
    assert_eq!(block_on(tw), 3);
    assert!(t0.elapsed().as_millis() >= 55, "completed without waiting for cross-thread wakes");
    println!("OK");
}'''),
]

for q in Q:
    q["prompt"] += "\n\nEnd your reply with the code block; no prose after it."
json.dump(Q, open("rust_questions.json","w"), indent=1)
print(len(Q), "rust tasks written")
