
During my diss I highlighted some of the pitfalls of worker-wrapper

These primarily occur when you return functions, pass them as arguments, or stick them in data structures
For example, 

```
let g = fun n ->
          let f = fun x y -> e in (* y dead in e *)
          f in
((g 1) 2 3) + ((g 4) 5 6)
```

Worker-wrapper does

```
let g = fun n -> 
          let f' = fun x -> e in
          let f = fun x y -> (f' x) in
          f in
((g 1) 2 3) + ((g 4) 5 6)
```

And then a naive implementation would directly inline

```
((fun x -> e[1/n]) 2) + ((fun x -> e[4/n]) 5)
```

Instead, what I want to do is insert another worker-wrapper for `g`:

```
let g = fun n -> 
          let f' = fun x -> e in
          let f = fun x y -> (f' x) in
          f in
((g 1) 2 3) + ((g 4) 5 6)

===>

let g' = fun n -> 
          let f' = fun x -> e in
          f' in
let g = fun n -> 
          let f' = (g' n) in
          let f = fun x y -> (f' x) in
          f in
((g 1) 2 3) + ((g 4) 5 6)
```

Then, we can inline `g` safely and get

```
let g' = fun n -> 
          let f' = fun x -> e in
          f' in
((g' 1) 2) + ((g' 4) 5)
```

We can do the same for function arguments

```
let h = fun g ->
   let f = fun x y -> ... in (* y dead *)
   ... (f 1 2) ... + (* big *)
   (g f)
```

Initial worker-wrapper and inlining for `f`:

```
let h = fun g ->
   let f' = fun x -> ... in
   ... (f' 1) ... + (* big *)
   (g (fun x y -> f' x))
```

Now, we create a wrapper for `h`:

```
let h' = fun g ->
   let f' = fun x -> ... in
   ... (f' 1) ... + (* big *)
   (g f')
let h = fun g -> 
   (h' (fun f' -> (g (fun x y -> (f' x)))))
```


We can play the same game with data structures.
It's a bit more complicated when reasoning about the code, but I bet looking at the inlined `foldr` and fixpoint would make it obvious.
Or at the types.

```
let g = fun n lst -> 
          let f = fun x y -> e in (* y dead in e *)
          f :: lst in
(foldr g [] [...])
```

```
let g = fun n lst -> 
          let f' = fun x -> e in
          let f = fun x y -> (f' x) in
          f :: lst in
(foldr g [] [...])
```

```
let g = fun n lst -> 
          let f' = fun x -> e in
          f' :: lst in
(map (fun f' -> (fun x y -> (f' x))) (* eta/worker-wrapper the data structure *)
     (foldr g [] [...]))
```

Catamorphism = `fold`
Anamorphism = `unfold` / `build`
Hylomorphism = `unfold` followed by `fold`
