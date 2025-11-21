# Skeletor
<div align=center>
  
[![Thumbnail](https://github.com/user-attachments/assets/3f5ec294-600e-4cd4-9049-7c0124801662)](https://youtu.be/RqCqg34G6Zg)

</div>


## Demo Projects
This is a pixelorama extension that add basic Skeletal animation capabilities to the software. You may play with this extension on one of the Demo Projects below.

<table style="margin-left:auto; margin-right:auto;">
  <tbody><tr>
    <td><h2>Laser Gun</h2></td>
    <td><h2>Robot</h2></td><td><h2><strong>Snake</strong></h2></td>
  </tr>
    <tr><td>
      <a href="https://github.com/user-attachments/files/23674501/Turret.Demo.Extract.Me.zip"><img src="https://github.com/user-attachments/assets/ae5837e2-e363-4312-85fe-882eb3250bc5" alt="Turret Demo" width="256px" height="256px">
    </a></td>
    <td>
      <a href="https://github.com/user-attachments/files/23674862/Character.Demo.Extract.Me.zip"><img src="https://github.com/user-attachments/assets/d692e6c0-3e25-468d-99b3-01df46a77438" alt="Character Demo" width="209px" height="301px">
    </a></td>
    <td>
       <a href="https://github.com/user-attachments/files/23676748/Snake.Demo.Extract.Me.zip"><img src="https://github.com/user-attachments/assets/4bcdfcd3-454a-41fe-8d0e-1db5710014e6" alt="Snake Demo" width="276px" height="300px">
    </a></td>
  </tr>
</tbody></table>

## Highlight Features:
<div align=center>
  
### 1. Basic movement:
You can move any bone in the skeleton and it's children will move with it.
  
  https://github.com/user-attachments/assets/b7b54324-013e-4ef6-9ad2-46cbc91caba4

### 2. Bone Chaining:
In chaining mode you are only allowed to rotate a bone. the children of the bones move with parent bone but preserve their rotation.
  
https://github.com/user-attachments/assets/190254b8-f62f-4ea6-831c-5ced66af898b

### 3. Tweening Support
Gererate In-Betweens from a chosen start frame to the current frame.

https://github.com/user-attachments/assets/11c7b4c1-26bc-430e-98ce-591356a67bf6

### 4. Draw <=> Pose Mode:

You can switch between the two views with ease.

https://github.com/user-attachments/assets/c3918ef7-fc7e-4c4f-ac00-5f4dc283e094

### 5. Quick set bones:
You can quickly place bones to roughly over their intended sprites with a single click.

https://github.com/user-attachments/assets/3f2f8328-a181-4533-80fe-db4521b1140d
</div>

## How to use:
1. There should be a Pixel Layer named "Pose Layer" in the project (It can be renamed later, once the extension has detected it). This Layer will be used to render the final "pose" of the frame.
2. The bones are given to groups (Arrange Groups as Bones in a skeleton).

## Controls (parts of the bone):
The extension gives you access to a new **Skeleton** tool (![Tool Image](https://github.com/user-attachments/assets/6002d741-87f9-42b2-9aee-acbb61bc91c0))

<table style="margin-left:auto; margin-right:auto;">
  <tbody><tr>
    <td><h2>Movement</h2></td>
    <td><h2>Rotation</h2></td>
  </tr>
    <tr><td>
      <img src="https://github.com/user-attachments/assets/ab7552fd-81e9-4e55-98fc-8224a2347669" alt="Movement" width="300px" height="300px">
    </a></td>
    <td>
      <img src="https://github.com/user-attachments/assets/7f7689fa-aa34-4b20-8963-e20e577604a7" alt="Rotation" width="300px" height="300px">
    </a></td>
    
  </tr>
</tbody></table>

1. **The bigger circle** is the pivot, the image of the bone will rotate around this pivot. The pivot is set by hovering over the circle then hold (`Ctrl` + `Left/Right` click) key and move the mouse. Also, moving the pivot using (`Left/Right` click) will move the image instead of setting pivot.
2. **Smaller circle** controls rotation. Hold (`Ctrl` + `Left/Right` click) with mouse movement to move the circle without rotating the image (this is just to move it somewhere more comfortable). Holding (`Left/Right` click) and mouse movement Will rotate image.
3. **The solid line** joining the two circles does the same as the above (however the width of the line won't change this time).

The rest of the important stuffs are explained in [this video](https://youtu.be/RqCqg34G6Zg).
